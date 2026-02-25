# server/src/utils/roles.py
from functools import wraps
from flask import request, jsonify  # если используешь Flask; адаптируй под свой фреймворк
from ..models.users import Users
from ..models.chat_members import ChatMembers

def get_user_role(user_id):
    u = Users.get_by_id(user_id)
    return u.role if u else None

def get_chat_role(chat_id, user_id):
    rec = ChatMembers.get_row(chat_id, user_id) if hasattr(ChatMembers, 'get_row') else None
    if rec:
        return rec.role
    return None

def require_global_role(*allowed_roles):
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            user = getattr(request, 'user', None)
            if not user:
                return jsonify({'ok': False, 'error': 'Unauthorized'}), 401
            role = get_user_role(user.id)
            if role not in allowed_roles:
                return jsonify({'ok': False, 'error': 'Forbidden'}), 403
            return f(*args, **kwargs)
        return wrapper
    return decorator

def require_chat_role(chat_id_arg='chat_id', allowed=('owner','moderator')):
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            user = getattr(request, 'user', None)
            if not user:
                return jsonify({'ok': False, 'error': 'Unauthorized'}), 401
            chat_id = kwargs.get(chat_id_arg) or request.json.get(chat_id_arg) or request.args.get(chat_id_arg)
            if not chat_id:
                return jsonify({'ok': False, 'error': 'chat_id required'}), 400
            role = get_chat_role(chat_id, user.id)
            if role not in allowed:
                return jsonify({'ok': False, 'error': 'Forbidden'}), 403
            return f(*args, **kwargs)
        return wrapper
    return decorator
