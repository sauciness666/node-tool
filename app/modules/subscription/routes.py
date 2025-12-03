# routes.py

from flask import Blueprint, render_template, jsonify, Response, make_response, request, url_for, abort
from flask_login import login_required, current_user
# 引入 update_node_custom_name 用于 DB 节点改名
from app.utils.db_manager import get_all_nodes, update_node_details, get_config, set_config, update_node_custom_name
from app.utils.scheduler import scheduler
import os
import sys         # 用于判断打包环境
import shutil      # 用于复制文件恢复模板
import requests    # 用于下载订阅
from app.utils.path_helper import get_external_config_path # 引入创建的路径处理工具
import json
import base64
import time
from datetime import datetime
import urllib.parse
import uuid
from io import BytesIO

from collections import defaultdict

from ruamel.yaml import YAML
from .link_parser import parse_proxy_link, get_emoji_flag, extract_nodes_from_content, fix_link_ipv6

bp = Blueprint('subscription', __name__, url_prefix='/subscription', template_folder='templates')

SUBSCRIPTION_CONFIG_KEY = 'external_subscriptions'
LEGACY_SUB_LIST_KEY = 'external_sub_urls'
LEGACY_SUB_SINGLE_KEY = 'external_sub_url'

def _normalize_subscription_entry(data, order_index=0):
    if not isinstance(data, dict):
        data = {'url': str(data) if data else ''}
    entry = {
        'id': data.get('id') or str(uuid.uuid4()),
        'name': (data.get('name') or '').strip(),
        'url': (data.get('url') or data.get('link') or '').strip(),
        'note': (data.get('note') or '').strip(),
        'enabled': bool(data.get('enabled', True)),
        'last_status': data.get('last_status'),
        'last_message': data.get('last_message', ''),
        'last_synced_at': data.get('last_synced_at'),
        'last_trigger': data.get('last_trigger', ''),
        'order': data.get('order', order_index)
    }
    return entry

def load_subscription_entries():
    entries = []
    raw = get_config(SUBSCRIPTION_CONFIG_KEY, default='')
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, list):
                for idx, item in enumerate(parsed):
                    entries.append(_normalize_subscription_entry(item, idx))
        except Exception as e:
            print(f"Error parsing {SUBSCRIPTION_CONFIG_KEY}: {e}")

    if not entries:
        legacy_raw = get_config(LEGACY_SUB_LIST_KEY, default='')
        legacy_list = []
        if legacy_raw:
            try:
                parsed = json.loads(legacy_raw)
                if isinstance(parsed, list):
                    legacy_list = [str(x) for x in parsed]
            except Exception:
                legacy_list = [line.strip() for line in legacy_raw.splitlines() if line.strip()]
        else:
            single = get_config(LEGACY_SUB_SINGLE_KEY, default='')
            if single:
                legacy_list = [line.strip() for line in single.splitlines() if line.strip()]

        for idx, url in enumerate(legacy_list):
            entries.append(_normalize_subscription_entry({'url': url}, idx))

    # 重新编号 order，避免出现重复
    for idx, item in enumerate(entries):
        item['order'] = idx
    return entries

def save_subscription_entries(entries):
    prepared = []
    for idx, item in enumerate(entries):
        normalized = _normalize_subscription_entry(item, idx)
        prepared.append(normalized)
    string_list = [i['url'] for i in prepared if i.get('url')]
    # 持久化主配置
    saved = set_config(SUBSCRIPTION_CONFIG_KEY, json.dumps(prepared, ensure_ascii=False), description='订阅管理-多订阅配置')
    # 兼容老字段
    set_config(LEGACY_SUB_LIST_KEY, json.dumps(string_list, ensure_ascii=False), description='订阅管理-订阅列表(兼容)')
    set_config(LEGACY_SUB_SINGLE_KEY, string_list[0] if string_list else '', description='订阅管理-单订阅(兼容)')
    return saved

def refresh_auto_sync_job():
    try:
        if not getattr(scheduler, 'app', None):
            return
        enabled = str(get_config('SUBSCRIPTION_AUTO_SYNC_ENABLED', '0')).lower() in ['1', 'true', 'yes']
        try:
            interval = max(int(get_config('SUBSCRIPTION_AUTO_SYNC_INTERVAL_MINUTES', 30)), 1)
        except (TypeError, ValueError):
            interval = 30

        if enabled:
            scheduler.add_job(
                id='subscription_auto_sync',
                func=auto_sync_subscriptions_job,
                trigger='interval',
                minutes=interval,
                max_instances=1,
                replace_existing=True,
                args=[]
            )
        else:
            if scheduler.get_job('subscription_auto_sync'):
                scheduler.remove_job('subscription_auto_sync')
    except Exception as e:
        print(f"[Subscription-AutoSync] 调整任务失败: {e}")

# ---------------------------------------------------------
# 新增辅助函数：自愈机制
# ---------------------------------------------------------
def check_and_restore_templates(target_dir):
    """
    自愈功能：检查外部目录是否缺失模板文件，如果缺失则从 exe 内部恢复
    """
    # 仅在打包环境 (Frozen) 下执行恢复逻辑
    # 开发环境下 sys.frozen 为 False，直接使用源码文件，不需要恢复
    if not getattr(sys, 'frozen', False):
        return

    # 内置资源的路径 (由 PyInstaller 解压在 _MEIPASS/bundled_templates)
    # 这个路径对应我们在 .spec 文件里定义的 target_dir
    base_path = sys._MEIPASS
    source_dir = os.path.join(base_path, 'bundled_templates')
    
    if not os.path.exists(source_dir):
        # 如果内置目录都不存在，说明打包有问题，跳过防止报错
        return

    # 需要检查的关键文件列表 (与 spec 文件中打包的一致)
    critical_files = [
        'clash_meta.yaml', 
        'customize.list', 
        'direct.list', 
        'install-singbox.sh'
    ]
    
    for filename in critical_files:
        target_file = os.path.join(target_dir, filename)
        # 如果目标文件不存在 (用户误删，或首次运行)，则从内置资源复制
        if not os.path.exists(target_file):
            source_file = os.path.join(source_dir, filename)
            if os.path.exists(source_file):
                try:
                    shutil.copy2(source_file, target_file)
                    print(f"[Auto-Restore] Restored missing file: {filename}")
                except Exception as e:
                    print(f"[Error] Failed to restore {filename}: {e}")

# ---------------------------------------------------------
# 主路径函数
# ---------------------------------------------------------
def get_nodes_dir():
    """
    获取节点配置文件存储目录
    增加打包环境判断逻辑 + 自愈逻辑
    """
    if getattr(sys, 'frozen', False):
        # [打包环境]
        # 如果是 exe 运行，强制定向到 exe 同级目录下的 'nodes' 文件夹
        nodes_dir = get_external_config_path('nodes')
    else:
        # [开发环境]
        # 保持原样，指向 app/subscription/nodes
        current_dir = os.path.dirname(os.path.abspath(__file__))
        nodes_dir = os.path.join(current_dir, 'nodes')

    # 1. 确保目录存在
    if not os.path.exists(nodes_dir):
        try: os.makedirs(nodes_dir)
        except OSError as e: print(f"Error creating nodes dir: {e}")
    
    # 2. 检查并恢复缺失的模板文件
    # 这一步保证了即使外部 nodes 文件夹是空的，程序启动后也会自动把
    # install-singbox.sh 等文件释放出来
    check_and_restore_templates(nodes_dir)
    
    return nodes_dir

# ---------------------------------------------------------
# 2. 本地节点管理工具 & 核心同步逻辑
# ---------------------------------------------------------
LOCAL_NODES_FILE = 'local_nodes.json'

def get_local_nodes_path():
    return os.path.join(get_nodes_dir(), LOCAL_NODES_FILE)

def load_local_nodes_raw():
    """
    [底层函数] 仅读取原始 JSON 数据，不进行业务逻辑处理
    """
    path = get_local_nodes_path()
    if not os.path.exists(path): return []
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except: return []

# 建立别名兼容旧代码调用
load_local_nodes = load_local_nodes_raw

def save_local_nodes(nodes):
    """保存节点列表到 JSON"""
    try:
        # 保存前按 sort_index 排序，保持文件整洁
        nodes.sort(key=lambda x: x.get('sort_index', 9999))
        with open(get_local_nodes_path(), 'w', encoding='utf-8') as f:
            json.dump(nodes, f, ensure_ascii=False, indent=2)
        return True
    except Exception as e:
        print(f"Error saving local nodes: {e}")
        return False

def merge_db_to_local_json():
    """
    将数据库节点同步到本地 JSON
    修改点：将 DB 节点的 is_fixed 改为 False，允许前端拖拽改变分组
    """
    db_nodes = get_all_nodes()
    local_nodes = load_local_nodes_raw()
    
    local_map = {n['uuid']: n for n in local_nodes}
    active_db_uuids = set()
    has_changes = False

    # --- 1. 同步 DB 节点 ---
    for db_node in db_nodes:
        uuid_str = str(db_node.uuid)
        active_db_uuids.add(uuid_str)
        
        # 获取 DB 权威数据
        db_name = db_node.custom_name or db_node.name
        links = db_node.get_links_dict()
        r_type = db_node.routing_type if db_node.routing_type is not None else -1
        region = db_node.region or 'DB'

        if uuid_str in local_map:
            # [更新]
            node = local_map[uuid_str]
            
            updates = {
                'name': db_name,
                'links': links,
                'routing_type': r_type,
                'region': region,
                'origin': 'db',
                'is_fixed': False  # 允许 DB 节点被拖拽移动
            }
            
            for k, v in updates.items():
                if node.get(k) != v:
                    node[k] = v
                    has_changes = True
            
            if 'sort_index' not in node:
                node['sort_index'] = 9999
                has_changes = True
                
        else:
            # [新增]
            new_node = {
                "uuid": uuid_str,
                "name": db_name,
                "links": links,
                "routing_type": r_type,
                "region": region,
                "origin": "db",
                "is_fixed": False, # 允许 DB 节点被拖拽移动
                "sort_index": 99999
            }
            local_nodes.append(new_node)
            has_changes = True

    # --- 2. 清理失效节点 ---
    final_nodes = []
    for node in local_nodes:
        is_db_node = node.get('origin') == 'db'
        
        if is_db_node and node['uuid'] not in active_db_uuids:
            has_changes = True
            continue 
            
        if not is_db_node:
            if node.get('origin') not in ['local', 'sub']:
                node['origin'] = 'local'
                node['is_fixed'] = False 
                has_changes = True

        final_nodes.append(node)
    
    if has_changes:
        save_local_nodes(final_nodes)
        return final_nodes
    
    return final_nodes
# ---------------------------------------------------------
# 3. 配置文件生成逻辑 (读取统一数据源)
# ---------------------------------------------------------
def sync_nodes_to_files():
    """
    生成 0.yaml 和 1.yaml
    强制将 YAML 中的 name 字段重写为 'Flag Proto-Name' 格式
    """
    # 1. 获取最新合并后的节点列表
    all_nodes = merge_db_to_local_json()
    
    # 2. 按 sort_index 排序
    all_nodes.sort(key=lambda x: x.get('sort_index', 0))

    proxies_map = {0: [], 1: []}
    count_summary = {0: 0, 1: 0}

    for node in all_nodes:
        r_type = node.get('routing_type', -1)
        if r_type not in proxies_map: continue
        
        links = node.get('links', {})
        node_name = node.get('name', 'Unknown')
        origin = node.get('origin', 'local')
        region = node.get('region')
        
        for proto, link in links.items():
            if link and link.strip():
                # 命名格式强制调整
                # 1. 确定国旗
                # 增加对 'sub' (外部订阅) 的判断，显示云朵图标
                if origin == 'db':
                    flag = get_emoji_flag(region)
                    name_prefix = f"{proto.lower()}-"   # DB 节点必须带协议前缀
                elif origin == 'sub':
                    flag = ''  # 外部订阅不显示国旗或标志，保留原始名称
                    name_prefix = ""    # 外部订阅节点：不带任何前缀
                else:
                    flag = '📝' # 本地手填标志
                    name_prefix = f"{proto.lower()}-"
                
                # 2. 构造强制名称：Flag Protocol-Name (例如: 🇸🇬 hy2-SG-NAT1)
                display_name = f"{flag} {name_prefix}{node_name}".strip()
                
                # 3. 调用解析器
                # 注意：虽然传入了 display_name，但解析器可能会优先读取 link 中的 #hash
                proxy_dict = parse_proxy_link(link.strip(), display_name, region)
                
                if proxy_dict:
                    # 无论 parse_proxy_link 返回的 name 是什么（可能是旧的后缀格式），
                    # 这里强制将其覆盖为我们刚刚构造的前缀格式。
                    proxy_dict['name'] = display_name
                    proxies_map[r_type].append(proxy_dict)
                    count_summary[r_type] += 1

    # --- 写入 YAML ---
    nodes_dir = get_nodes_dir()
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=2, offset=0)
    # 4096是为了组合模板时候不被截断
    yaml.width = 4096

    try:
        with open(os.path.join(nodes_dir, '0.yaml'), 'w', encoding='utf-8') as f:
            yaml.dump({'proxies': proxies_map[0]}, f)
        with open(os.path.join(nodes_dir, '1.yaml'), 'w', encoding='utf-8') as f:
            yaml.dump({'proxies': proxies_map[1]}, f)  
        return True, f"同步成功: 直连 {count_summary[0]}, 落地 {count_summary[1]}"
    except Exception as e:
        return False, f"写入失败: {str(e)}"

# ---------------------------------------------------------
# 4. 统计逻辑
# ---------------------------------------------------------
def get_stats_data():
    """获取统计信息：修改为统一从合并列表获取"""
    # 触发同步，获取全量数据
    all_nodes = merge_db_to_local_json()

    stats = {
        "total": len(all_nodes),
        "direct": 0,
        "land": 0,
        "blocked": 0,
        "protocols": {}
    }

    PROTOCOL_NORMALIZE_MAP = {
        'hy2': 'Hysteria2', 'hysteria2': 'Hysteria2',
        'ss': 'Shadowsocks', 'shadowsocks': 'Shadowsocks',
        'vless': 'VLESS', 'vmess': 'VMess',
        'trojan': 'Trojan', 'tuic': 'TUIC', 'socks5': 'Socks5'
    }

    for node in all_nodes:
        r_type = node.get('routing_type', -1)
        if r_type == 0: stats['direct'] += 1
        elif r_type == 1: stats['land'] += 1
        else: stats['blocked'] += 1
        
        links = node.get('links', {})
        for proto, link in links.items():
            if link and link.strip():
                key = proto.lower()
                normalized = PROTOCOL_NORMALIZE_MAP.get(key, proto)
                stats['protocols'][normalized] = stats['protocols'].get(normalized, 0) + 1
    
    return stats

# ---------------------------------------------------------
# 数据库存储并处理订阅设置 (辅助函数保持不变)
# ---------------------------------------------------------
def get_sub_settings():
    entries = load_subscription_entries()
    url_list = [item['url'] for item in entries if item.get('url')]
    auto_enabled = str(get_config('SUBSCRIPTION_AUTO_SYNC_ENABLED', '0')).lower() in ['1', 'true', 'yes', 'on']
    try:
        auto_interval = int(get_config('SUBSCRIPTION_AUTO_SYNC_INTERVAL_MINUTES', 30))
        if auto_interval < 1:
            auto_interval = 1
    except (TypeError, ValueError):
        auto_interval = 30
    return {
        'fixed_domain': get_config('fixed_domain', default=''),
        'api_token': get_config('api_token', default='default'),
        'external_subscriptions': entries,
        'external_sub_urls': url_list,
        'external_sub_url': '\n'.join(url_list),
        'sub_auto_enabled': auto_enabled,
        'sub_auto_interval': auto_interval
    }

def verify_request_token():
    token = request.args.get('token')
    settings = get_sub_settings()
    if token != settings.get('api_token', 'default'):
        abort(403, description="Invalid Access Token")

def get_base_url():
    settings = get_sub_settings()
    fixed = settings.get('fixed_domain', '').strip()
    if fixed: return fixed.rstrip('/')
    
    scheme = request.headers.get('X-Forwarded-Proto', request.scheme)
    host = request.headers.get('X-Forwarded-Host') or request.headers.get('Host') or request.host
    if ':' not in host and request.headers.get('X-Forwarded-Port'):
        host = f"{host}:{request.headers.get('X-Forwarded-Port')}"
    return f"{scheme}://{host}"

# ---------------------------------------------------------
# 5. 路由视图函数
# ---------------------------------------------------------
@bp.route('/')
@login_required
def manager():
    """订阅管理主页"""
    stats = get_stats_data()
    settings = get_sub_settings()
    base_url = get_base_url()
    token = settings.get('api_token', 'default')
    
    clash_url = f"{base_url}/subscription/clash?token={token}"
    v2ray_url = f"{base_url}/subscription/base64/all?token={token}"
    script_url = f"{base_url}{url_for('subscription.download_singbox_script')}"
    callback_url = f"{base_url}{url_for('subscription.add_node_callback')}"
    
    return render_template('sub_manager.html', stats=stats, clash_url=clash_url, 
                           v2ray_url=v2ray_url, script_url=script_url, 
                           callback_url=callback_url, token=token, 
                           settings=settings, current_base_url=base_url)

@bp.route('/api/settings/update', methods=['POST'])
@login_required
def update_settings_api():
    """API: 更新设置"""
    data = request.get_json()
    is_saved = False
    job_should_refresh = False
    if 'domain' in data:
        domain = data.get('domain', '').strip()
        if domain and not domain.startswith('http'): domain = 'http://' + domain
        if set_config('fixed_domain', domain, description='订阅管理-固定域名'): is_saved = True
    if 'api_token' in data:
        if set_config('api_token', data.get('api_token', '').strip(), description='订阅管理-安全Token'): is_saved = True
    # 订阅列表保存：优先接收结构化 sub_items，其次兼容 sub_urls/sub_url
    new_entries_payload = None
    if isinstance(data.get('sub_items'), list):
        raw_items = data.get('sub_items')
        existing = {item['id']: item for item in load_subscription_entries()}
        prepared = []
        for idx, item in enumerate(raw_items):
            if not isinstance(item, dict):
                continue
            entry_id = item.get('id') or str(uuid.uuid4())
            base = existing.get(entry_id, {})
            prepared.append({
                'id': entry_id,
                'name': (item.get('name') or '').strip(),
                'url': (item.get('url') or '').strip(),
                'note': (item.get('note') or '').strip(),
                'enabled': bool(item.get('enabled', True)),
                'last_status': base.get('last_status'),
                'last_message': base.get('last_message', ''),
                'last_synced_at': base.get('last_synced_at'),
                'last_trigger': base.get('last_trigger'),
                'order': idx
            })
        new_entries_payload = prepared
    elif isinstance(data.get('sub_urls'), list):
        cleaned = [u.strip() for u in data.get('sub_urls') if isinstance(u, str) and u.strip()]
        new_entries_payload = [{
            'id': str(uuid.uuid4()),
            'name': '',
            'url': url,
            'enabled': True,
            'note': ''
        } for url in cleaned]
    elif 'sub_url' in data:
        raw = data.get('sub_url', '')
        cleaned = [u.strip() for u in raw.splitlines() if u.strip()]
        new_entries_payload = [{
            'id': str(uuid.uuid4()),
            'name': '',
            'url': url,
            'enabled': True,
            'note': ''
        } for url in cleaned]

    if new_entries_payload is not None:
        if save_subscription_entries(new_entries_payload):
            is_saved = True

    if 'sub_auto_enabled' in data:
        enabled_val = data.get('sub_auto_enabled')
        enabled = False
        if isinstance(enabled_val, bool):
            enabled = enabled_val
        elif isinstance(enabled_val, str):
            enabled = enabled_val.lower() in ['1', 'true', 'yes', 'on']
        elif isinstance(enabled_val, (int, float)):
            enabled = int(enabled_val) != 0
        if set_config('SUBSCRIPTION_AUTO_SYNC_ENABLED', 1 if enabled else 0, description='订阅自动同步开关'):
            is_saved = True
            job_should_refresh = True

    if 'sub_auto_interval' in data:
        try:
            interval = max(int(data.get('sub_auto_interval')), 1)
            if set_config('SUBSCRIPTION_AUTO_SYNC_INTERVAL_MINUTES', interval, description='订阅自动同步间隔(分)'):
                is_saved = True
                job_should_refresh = True
        except (TypeError, ValueError):
            pass

    if job_should_refresh:
        refresh_auto_sync_job()
    return jsonify({'status': 'success' if is_saved else 'error', 'message': '设置已保存' if is_saved else '保存失败'})

@bp.route('/api/token/refresh', methods=['POST'])
@login_required
def refresh_token_api():
    """API: 刷新 Token"""
    new_token = str(uuid.uuid4()).replace('-', '')[:16]
    if set_config('api_token', new_token, description='订阅管理-安全Token'):
        return jsonify({'status': 'success', 'token': new_token, 'message': 'Token 已刷新'})
    return jsonify({'status': 'error', 'message': '刷新失败'}), 500

@bp.route('/clash')
def download_clash_config():
    """下载 Clash 配置文件"""
    verify_request_token()
    
    try:
        base_url = get_base_url()
        token = get_sub_settings().get('api_token', 'default')
        timestamp = int(time.time())
        path = os.path.join(get_nodes_dir(), 'clash_meta.yaml')
        
        if not os.path.exists(path): return "Error: Template not found.", 404
        
        yaml = YAML()
        yaml.preserve_quotes = True
        yaml.indent(mapping=2, sequence=4, offset=2)
        with open(path, 'r', encoding='utf-8') as f: config_data = yaml.load(f)
        
        # 更新 Provider URL
        if 'proxy-providers' in config_data:
            for name, p in config_data['proxy-providers'].items():
                if '0.yaml' in p.get('path', '') or '/raw/0' in p.get('url', '') or '中转' in name:
                    p['url'] = f"{base_url}/subscription/raw/0?token={token}&t={timestamp}"
                    p['interval'] = 300
                elif '1.yaml' in p.get('path', '') or '/raw/1' in p.get('url', '') or '落地' in name:
                    p['url'] = f"{base_url}/subscription/raw/1?token={token}&t={timestamp}"
                    p['interval'] = 300
        
        if 'rule-providers' in config_data:
            for name, p in config_data['rule-providers'].items():
                if 'direct' in name or 'direct' in p.get('path', ''):
                    p['url'] = f"{base_url}/subscription/list/direct?token={token}&t={timestamp}"
                elif 'customize' in name or 'customize' in p.get('path', ''):
                    p['url'] = f"{base_url}/subscription/list/customize?token={token}&t={timestamp}"

        out = BytesIO()
        yaml.dump(config_data, out)
        resp = make_response(out.getvalue())
        resp.headers["Content-Disposition"] = "attachment; filename=clash_meta_config.yaml"
        resp.mimetype = "text/yaml; charset=utf-8"
        resp.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
        return resp
    except Exception as e: return f"Error: {str(e)}", 500

@bp.route('/install-singbox.sh')
def download_singbox_script():
    path = os.path.join(get_nodes_dir(), 'install-singbox.sh')
    if not os.path.exists(path): return Response("echo 'Error not found.'", mimetype='text/plain')
    with open(path, 'r', encoding='utf-8') as f: return Response(f.read(), mimetype='text/plain')


@bp.route('/api/stats')
@login_required
def get_stats_api():
    try:
        # 1. 触发文件同步：
        # 此函数会执行：a) DB -> local_nodes.json (缓存)
        #              b) local_nodes.json -> 0.yaml/1.yaml (文件生成)
        success, message = sync_nodes_to_files() 
        
        # 2. 获取统计数据
        stats = get_stats_data()
        
        # 如果文件同步失败，返回一个警告状态，但仍带上统计信息
        if not success:
            return jsonify({'status': 'warning', 'message': message, 'stats': stats})

        # 成功则返回状态和统计数据
        return jsonify({'status': 'success', 'stats': stats})
        
    except Exception as e:
        # 如果发生其他异常（例如 DB 读取错误），则返回错误
        return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/api/sync_files', methods=['POST'])
@login_required
def sync_files_api():
    """API: 手动触发同步"""
    success, message = sync_nodes_to_files()
    return jsonify({'status': 'success' if success else 'error', 'message': message})

# ---------------------------------------------------------
# 节点管理 API (统一管理 DB 和 Local)
# ---------------------------------------------------------

@bp.route('/api/nodes/list', methods=['GET'])
@login_required
def get_nodes_list_api():
    """
    API: 获取节点列表
    修改：调用 merge_db_to_local_json 获取统一列表并按 sort_index 排序
    """
    try:
        nodes = merge_db_to_local_json() # 获取最新同步数据
        nodes.sort(key=lambda x: x.get('sort_index', 0)) # 排序
        
        # 补充前端需要的辅助字段
        for node in nodes:
            # is_db 字段方便前端判断图标
            node['is_db'] = (node.get('origin') == 'db')
            node['is_local'] = (node.get('origin') == 'local')
            node['is_sub'] = (node.get('origin') == 'sub')
            # 协议列表
            node['protocols'] = list(node.get('links', {}).keys())
            
        return jsonify({'status': 'success', 'nodes': nodes})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500


# ---------------------------------------------------------
# 从订阅获取节点并保存到 local_nodes.json
# ---------------------------------------------------------
def run_subscription_sync(selected_ids=None, urls_override=None, triggered_by='manual'):
    entries = load_subscription_entries()
    entry_map = {entry['id']: entry for entry in entries}

    tasks = []

    def _clean_urls(raw_urls):
        if not raw_urls:
            return []
        cleaned = []
        for val in raw_urls:
            if isinstance(val, str):
                candidate = val.strip()
                if candidate:
                    cleaned.append(candidate)
        return cleaned

    if urls_override:
        url_list = _clean_urls(urls_override)
        for idx, url in enumerate(url_list):
            tasks.append({
                'id': f'temp-{idx}',
                'name': f'临时订阅 {idx + 1}',
                'url': url,
                'note': '',
                'enabled': True,
                'temporary': True
            })
    else:
        if selected_ids:
            for sid in selected_ids:
                entry = entry_map.get(sid)
                if entry and entry.get('enabled', True):
                    tasks.append(entry)
        else:
            for entry in entries:
                if entry.get('enabled', True):
                    tasks.append(entry)

    if not tasks:
        return {
            'status': 'error',
            'message': '没有启用的订阅链接',
            'reports': []
        }

    aggregated_nodes = []
    reports = []
    for entry in tasks:
        report = {
            'id': entry.get('id'),
            'alias': entry.get('name') or '',
            'url': entry.get('url'),
            'note': entry.get('note', ''),
            'status': 'pending',
            'message': '',
            'fetched': 0,
            'new': 0,
            'updated': 0,
            'errors': [],
            'trigger': triggered_by
        }

        if not entry.get('enabled', True) and not entry.get('temporary'):
            report['status'] = 'disabled'
            report['message'] = '此订阅已被禁用'
            reports.append(report)
            continue

        url = (entry.get('url') or '').strip()
        if not url:
            report['status'] = 'error'
            report['message'] = 'URL 为空'
            reports.append(report)
            continue

        try:
            resp = requests.get(url, timeout=20, headers={'User-Agent': 'v2rayN/6.0'})
            resp.raise_for_status()
            content = resp.text
            extracted = extract_nodes_from_content(content)
            if extracted:
                for item in extracted:
                    item['source_id'] = entry.get('id')
                    aggregated_nodes.append(item)
                report['status'] = 'success'
                report['fetched'] = len(extracted)
                report['message'] = f'解析 {len(extracted)} 个节点'
            else:
                report['status'] = 'empty'
                report['message'] = '订阅内容为空或无法解析'
        except Exception as e:
            report['status'] = 'error'
            report['message'] = '下载失败'
            report['errors'].append(str(e))

        reports.append(report)

    if not aggregated_nodes:
        # 更新同步时间，保存状态（即便失败）
        now_iso = datetime.utcnow().isoformat()
        touched = False
        for report in reports:
            report['synced_at'] = now_iso
            entry = entry_map.get(report.get('id'))
            if entry:
                entry['last_synced_at'] = now_iso
                entry['last_status'] = report['status']
                entry['last_message'] = report['message']
                entry['last_trigger'] = triggered_by
                touched = True
        if touched:
            save_subscription_entries(entries)

        status_values = {r['status'] for r in reports}
        overall_status = 'error' if 'success' not in status_values else 'warning'
        overall_message = '未获取到可用节点'
        return {
            'status': overall_status,
            'message': overall_message,
            'reports': reports,
            'synced_at': now_iso,
            'triggered_by': triggered_by
        }

    local_nodes = load_local_nodes_raw()
    new_node_names = set()
    sub_node_map = {n['name']: n for n in local_nodes if n.get('origin') == 'sub'}
    source_stats = defaultdict(lambda: {'new': 0, 'updated': 0})

    for item in aggregated_nodes:
        name = item['name']
        proto = item['protocol']
        link = item['link']
        source_id = item.get('source_id')

        new_node_names.add(name)

        if name in sub_node_map:
            target = sub_node_map[name]
            target.setdefault('links', {})[proto] = link
            if source_id:
                target['sub_source_id'] = source_id
            source_stats[source_id]['updated'] += 1
        else:
            new_node = {
                "uuid": str(uuid.uuid4()),
                "name": name,
                "links": {proto: link},
                "routing_type": -1,
                "origin": "sub",
                "is_fixed": False,
                "sort_index": 99999,
                "sub_source_id": source_id
            }
            local_nodes.append(new_node)
            sub_node_map[name] = new_node
            source_stats[source_id]['new'] += 1

    initial_count = len(local_nodes)
    local_nodes = [
        n for n in local_nodes
        if not (n.get('origin') == 'sub' and n['name'] not in new_node_names)
    ]
    count_deleted = initial_count - len(local_nodes)

    save_local_nodes(local_nodes)
    sync_nodes_to_files()

    total_new = sum(stats['new'] for stats in source_stats.values())
    total_updated = sum(stats['updated'] for stats in source_stats.values())
    synced_at_iso = datetime.utcnow().isoformat()

    # 更新报告中的 new/updated 并生成更友好的信息
    for report in reports:
        stats = source_stats.get(report.get('id'), {'new': 0, 'updated': 0})
        report['new'] = stats['new']
        report['updated'] = stats['updated']
        report['synced_at'] = synced_at_iso
        if report['status'] == 'success':
            if stats['new'] == 0 and stats['updated'] == 0:
                report['message'] = '解析成功，但未产生变更'
            else:
                report['message'] = f"新增 {stats['new']}，更新 {stats['updated']}"

    touched = False
    for report in reports:
        entry = entry_map.get(report.get('id'))
        if entry:
            entry['last_synced_at'] = synced_at_iso
            entry['last_status'] = report['status']
            entry['last_message'] = report['message']
            entry['last_trigger'] = triggered_by
            touched = True

    if touched:
        save_subscription_entries(entries)

    overall_msg = f"同步完成：新增 {total_new}，更新 {total_updated}"
    if count_deleted > 0:
        overall_msg += f'，清理失效 {count_deleted}'

    return {
        'status': 'success',
        'message': overall_msg,
        'reports': reports,
        'summary': {
            'new': total_new,
            'updated': total_updated,
            'deleted': count_deleted
        },
        'synced_at': synced_at_iso,
        'triggered_by': triggered_by
    }

def auto_sync_subscriptions_job():
    """供 APScheduler 调用的自动同步任务"""
    try:
        result = run_subscription_sync(triggered_by='scheduler')
        status = result.get('status')
        msg = result.get('message')
        print(f"[Subscription-AutoSync] status={status} msg={msg}")
    except Exception as e:
        print(f"[Subscription-AutoSync] 执行失败: {e}")

@bp.route('/api/local_nodes/fetch_from_sub', methods=['POST'])
@login_required
def fetch_from_sub_api():
    """
    API: 从外部订阅下载并解析节点（支持多订阅、审计信息）
    """
    try:
        data = request.get_json() or {}
        urls_override = None
        if isinstance(data.get('urls'), list):
            urls_override = data.get('urls')
        elif isinstance(data.get('urls'), str):
            urls_override = [line.strip() for line in data.get('urls').splitlines() if line.strip()]
        selected_ids = data.get('sub_ids') if isinstance(data.get('sub_ids'), list) else None

        triggered_by = 'manual'
        if current_user and getattr(current_user, 'is_authenticated', False):
            triggered_by = f'user:{current_user.username}'

        result = run_subscription_sync(selected_ids=selected_ids, urls_override=urls_override, triggered_by=triggered_by)
        status_code = 200 if result.get('status') in ['success', 'warning'] else 400
        return jsonify(result), status_code

    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/api/local_nodes/add', methods=['POST'])
@login_required
def add_local_node_api():
    """API: 添加本地节点"""
    try:
        data = request.get_json()
        name, proto, link = data.get('name'), data.get('protocol'), data.get('link')
        if not all([name, proto, link]): return jsonify({'status': 'error', 'message': '参数不完整'}), 400
        
        local_nodes = load_local_nodes_raw()
        # 查找是否存在同名本地节点 (排除 DB 节点)
        target = next((n for n in local_nodes if n['name'] == name and n.get('origin') != 'db'), None)
        
        if target:
            target.setdefault('links', {})[proto] = link
            msg = f"协议 {proto} 已合并到本地节点 {name}"
        else:
            local_nodes.append({
                "uuid": str(uuid.uuid4()),
                "name": name,
                "links": {proto: link},
                "routing_type": 1, # 默认直连
                "origin": "local",
                "is_fixed": False,
                "sort_index": 99999
            })
            msg = f"本地节点 {name} 已创建"
            
        save_local_nodes(local_nodes)
        return jsonify({'status': 'success', 'message': msg})
    except Exception as e: return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/api/local_nodes/rename', methods=['POST'])
@login_required
def rename_local_node_api():
    """
    API: 重命名节点
    修改：根据 origin 判断调用 DB 函数还是修改本地 JSON
    """
    try:
        data = request.get_json()
        target_uuid = data.get('uuid')
        new_name = data.get('name')
        if not target_uuid or not new_name: return jsonify({'status': 'error', 'message': '参数不完整'}), 400
            
        local_nodes = load_local_nodes_raw()
        target_node = next((n for n in local_nodes if n['uuid'] == target_uuid), None)
        
        if not target_node: return jsonify({'status': 'error', 'message': '未找到节点'}), 404
            
        if target_node.get('origin') == 'db':
            # DB 节点：调用数据库更新
            success = update_node_custom_name(target_uuid, new_name)
            if not success: return jsonify({'status': 'error', 'message': '数据库更新失败'}), 500
        else:
            # Local 节点：直接更新 JSON
            target_node['name'] = new_name
            save_local_nodes(local_nodes)
            
        sync_nodes_to_files() # 重新同步以刷新配置
        return jsonify({'status': 'success', 'message': '重命名成功'})
    except Exception as e: return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/api/local_nodes/update_links', methods=['POST'])
@login_required
def update_local_node_links_api():
    """API: 更新链接 (仅限本地节点)"""
    try:
        data = request.get_json()
        uuid_val, links = data.get('uuid'), data.get('links')
        local_nodes = load_local_nodes_raw()
        node = next((n for n in local_nodes if n['uuid'] == uuid_val), None)
        
        if not node: return jsonify({'status': 'error', 'message': '节点不存在'}), 404
        # 防止修改 DB 节点链接
        if node.get('origin') == 'db': return jsonify({'status': 'error', 'message': '数据库节点链接不可在此修改'}), 403
        
        cleaned = {k: v for k, v in links.items() if v and v.strip()}
        if not cleaned:
            local_nodes.remove(node)
            msg = '节点已清空并删除'
        else:
            node['links'] = cleaned
            msg = '链接已更新'
            
        save_local_nodes(local_nodes)
        sync_nodes_to_files()
        return jsonify({'status': 'success', 'message': msg})
    except Exception as e: return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/api/local_nodes/delete', methods=['POST'])
@login_required
def delete_local_node_api():
    """API: 删除节点 (仅限本地节点)"""
    try:
        uuid_val = request.get_json().get('uuid')
        local_nodes = load_local_nodes_raw()
        node = next((n for n in local_nodes if n['uuid'] == uuid_val), None)
        
        if not node: return jsonify({'status': 'error', 'message': '节点不存在'}), 404
        if node.get('origin') == 'db': return jsonify({'status': 'error', 'message': '无法删除数据库同步节点'}), 403
        
        local_nodes.remove(node)
        save_local_nodes(local_nodes)
        sync_nodes_to_files()
        return jsonify({'status': 'success', 'message': '节点已删除'})
    except Exception as e: return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/api/nodes/clear_subscription', methods=['POST'])
@login_required
def clear_subscription_nodes_api():
    """
    API: 清除所有订阅节点 (origin='sub')
    保留手动添加的 (local) 和数据库同步的 (db) 节点
    """
    try:
        # 1. 读取当前节点列表
        local_nodes = load_local_nodes_raw()
        initial_count = len(local_nodes)
        
        # 2. 过滤列表：只保留 origin 不为 'sub' 的节点
        # 这样会把 'sub' 节点全部剔除，保留 'local' 和 'db'
        new_nodes = [n for n in local_nodes if n.get('origin') != 'sub']
        
        deleted_count = initial_count - len(new_nodes)
        
        # 3. 如果有变化，保存并触发同步
        if deleted_count > 0:
            save_local_nodes(new_nodes)
            sync_nodes_to_files() # 立即重新生成 yaml，让更改生效
            msg = f'已清除 {deleted_count} 个订阅节点'
        else:
            msg = '没有可清除的订阅节点'
            
        return jsonify({'status': 'success', 'message': msg})
        
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/api/local_nodes/delete_protocol', methods=['POST'])
@login_required
def delete_local_node_protocol_api():
    """API: 删除协议 (仅限本地节点)"""
    try:
        data = request.get_json()
        uuid_val, proto = data.get('uuid'), data.get('protocol')
        local_nodes = load_local_nodes_raw()
        node = next((n for n in local_nodes if n['uuid'] == uuid_val), None)
        
        if not node: return jsonify({'status': 'error', 'message': '节点不存在'}), 404
        if node.get('origin') == 'db': return jsonify({'status': 'error', 'message': '无法修改数据库节点'}), 403
        
        if 'links' in node and proto in node['links']:
            del node['links'][proto]
            msg = '协议已删除'
            if not node['links']:
                local_nodes.remove(node)
                msg += '，节点为空已清理'
            save_local_nodes(local_nodes)
            sync_nodes_to_files()
            return jsonify({'status': 'success', 'message': msg})
        return jsonify({'status': 'error', 'message': '协议不存在'}), 404
    except Exception as e: return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/api/nodes/update_routing', methods=['POST'])
@login_required
def update_nodes_routing_api():
    """
    API: 更新节点排序和分组
    修改：支持 DB 节点的分组修改。
    如果检测到 DB 节点的分组(routing_type)发生变化，自动同步回数据库。
    """
    try:
        data = request.get_json()
        local_nodes = load_local_nodes_raw()
        node_map = {n['uuid']: n for n in local_nodes}
        
        groups = [('direct', 0), ('land', 1), ('blocked', -1)]
        current_index = 0
        
        for group_name, type_code in groups:
            uuid_list = data.get(group_name, [])
            for uuid_val in uuid_list:
                if uuid_val in node_map:
                    node = node_map[uuid_val]
                    
                    # 1. 更新排序索引 (所有节点)
                    node['sort_index'] = current_index
                    current_index += 1
                    
                    # 2. 更新分组 (路由类型)
                    old_type = node.get('routing_type', -1)
                    
                    # 如果分组发生了变化
                    if old_type != type_code:
                        if node.get('origin') == 'db':
                            # [核心修改] DB 节点：调用数据库函数更新 routing_type
                            # update_node_details 需要完整信息，我们从 local_nodes 中读取当前的 links 和 name
                            success = update_node_details(
                                uuid_val, 
                                node.get('links', {}), 
                                type_code, # 新的路由类型
                                node.get('name') 
                            )
                            if success:
                                node['routing_type'] = type_code
                            else:
                                print(f"Failed to update DB node routing: {uuid_val}")
                        else:
                            # Local 节点：直接更新 JSON
                            node['routing_type'] = type_code
        
        # 保存 JSON 并生成配置文件
        save_local_nodes(local_nodes)
        sync_nodes_to_files()
        
        return jsonify({'status': 'success', 'message': '排序与分组已更新 (DB已同步)'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/base64/all')
def download_v2ray_base64():
    """下载 Base64 订阅"""
    verify_request_token()
    # 1. 统一从 merged 列表获取所有节点
    all_nodes = merge_db_to_local_json()
    # 2. 允许直连(0)、落地(1)，以及尚未分类的订阅节点 (routing_type=-1 或 None)
    # 避免用户尚未手动分组时订阅内容为空
    nodes_to_include = []
    for node in all_nodes:
        r_type = node.get('routing_type')
        if r_type in [0, 1]:
            nodes_to_include.append(node)
            continue
        if node.get('origin') == 'sub' and (r_type is None or r_type == -1):
            nodes_to_include.append(node)

    # 3. 按 sort_index 排序
    nodes_to_include.sort(key=lambda x: x.get('sort_index', 0))
    links = []
    for node in nodes_to_include:
        links_dict = node.get('links', {})
        name = node.get('name', 'Unknown')
        origin = node.get('origin', 'local')
        region = node.get('region', 'LOC')
        
        # 增加对类型的图标判断
        flag = get_emoji_flag(region) if origin == 'db' else ('📝' if origin == 'local' else '')
        for proto, link in links_dict.items():
            if link and link.strip():
                # 2. 计算 name_prefix (在协议循环内，使用当前的 proto)
                name_prefix = ""
                if origin == 'db' or origin == 'local':
                    # 只有 DB 和 Local 节点需要协议前缀
                    name_prefix = f"{proto.lower()}-"
                # origin == 'sub' 时，name_prefix 保持空字符串
                
                link = fix_link_ipv6(link) # 提高对ipv6的兼容性
                
                # 3. 构造最终名称
                full_name = f"{flag} {name_prefix}{name}".strip()
                
                safe_name = urllib.parse.quote(full_name)
                if '#' in link: link = link.split('#')[0]
                links.append(f"{link}#{safe_name}")

    joined = "\n".join(links)
    # 如果传入 ?raw=1 则直接返回原始文本，便于调试
    try:
        raw_flag = str(request.args.get('raw', '')).lower() in ['1', 'true', 'yes']
    except Exception:
        raw_flag = False

    if raw_flag:
        return Response(joined, mimetype='text/plain; charset=utf-8')

    b64 = base64.b64encode(joined.encode('utf-8')).decode('utf-8')
    return Response(b64, mimetype='text/plain')

@bp.route('/api/callback/add_node', methods=['POST'])
def add_node_callback():
    """API: 脚本回调自动添加节点 (视为 Local 节点)"""
    try:
        data = request.get_json()
        name, proto, link = data.get('name'), data.get('protocol'), data.get('link')
        if not all([name, proto, link]): return jsonify({'status': 'error', 'message': 'Missing data'}), 400
        
        local_nodes = load_local_nodes_raw()
        target = next((n for n in local_nodes if n['name'] == name and n.get('origin') == 'local'), None)
        
        if target:
            target.setdefault('links', {})[proto] = link
            msg = f"已合并到节点 {name}"
        else:
            local_nodes.append({
                "uuid": str(uuid.uuid4()),
                "name": name,
                "links": {proto: link},
                "routing_type": 1,
                "origin": "local",
                "is_fixed": False,
                "sort_index": 99999
            })
            msg = f"自动添加节点 {name}"
        save_local_nodes(local_nodes)
        sync_nodes_to_files()
        return jsonify({'status': 'success', 'message': msg})
    except Exception as e: return jsonify({'status': 'error', 'message': str(e)}), 500

@bp.route('/raw/<int:routing_type>')
def download_raw_subscription(routing_type):
    verify_request_token()
    filename = '0.yaml' if routing_type == 0 else '1.yaml'
    path = os.path.join(get_nodes_dir(), filename)
    if not os.path.exists(path): sync_nodes_to_files()
    content = "proxies: []"
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f: content = f.read()
    resp = make_response(content)
    resp.mimetype = "text/yaml; charset=utf-8"
    resp.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    return resp

@bp.route('/list/<list_type>')
def download_rule_list(list_type):
    verify_request_token()
    filename = 'direct.list' if list_type == 'direct' else 'customize.list'
    path = os.path.join(get_nodes_dir(), filename)
    if not os.path.exists(path): path += '.txt'
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f: return Response(f.read(), mimetype='text/plain')
    return "", 404

@bp.route('/api/rules', methods=['GET', 'POST'])
@login_required
def handle_rules():
    filename = request.args.get('file')
    if filename not in ['direct.list', 'customize.list', 'install-singbox.sh']: return jsonify({'error': 'invalid'}), 400
    path = os.path.join(get_nodes_dir(), filename)
    if request.method == 'GET':
        if not os.path.exists(path): return jsonify({'content': ''})
        with open(path, 'r', encoding='utf-8') as f: return jsonify({'status': 'success', 'content': f.read()})
    else:
        content = request.get_json().get('content', '')
        if filename.endswith('.sh'): content = content.replace('\r\n', '\n')
        with open(path, 'w', encoding='utf-8') as f: f.write(content)
        return jsonify({'status': 'success'})

@bp.route('/api/rule_template', methods=['GET', 'POST'])
@login_required
def handle_rule_template():
    path = os.path.join(get_nodes_dir(), 'clash_meta.yaml')
    if request.method == 'GET':
        if not os.path.exists(path): return jsonify({'content': ''})
        with open(path, 'r', encoding='utf-8') as f: return jsonify({'status': 'success', 'content': f.read()})
    else:
        with open(path, 'w', encoding='utf-8') as f: f.write(request.get_json().get('content', ''))
        return jsonify({'status': 'success'})
