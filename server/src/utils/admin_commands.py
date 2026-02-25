# server/src/utils/admin_commands.py
from flask import request, jsonify
from .roles import require_global_role

# whitelist функций — каждая функция выполняет безопасную операцию, не raw SQL
def cmd_backup(args):
    # триггер job backup, не raw SQL
    return {'ok': True, 'msg': 'Backup started'}

def cmd_reindex(args):
    # безопасный вызов, например, через subprocess, но с проверкой
    return {'ok': True, 'msg': 'Reindex scheduled'}

ADMIN_COMMANDS = {
    'backup': cmd_backup,
    'reindex': cmd_reindex,
}

# пример Flask route
@require_global_role('admin', 'creator')
def handle_admin_command():
    payload = request.json or {}
    cmd = payload.get('cmd')
    args = payload.get('args', {})
    if cmd not in ADMIN_COMMANDS:
        return jsonify({'ok': False, 'error': 'Unknown command'}), 400
    result = ADMIN_COMMANDS[cmd](args)
    return jsonify(result)
