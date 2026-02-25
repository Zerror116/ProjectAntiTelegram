# server/src/models/admin_actions.py
import datetime
from sqlalchemy import String, DateTime, JSON
from sqlalchemy.orm import mapped_column, Session
from .db import AbstractModel, engine

class AdminActions(AbstractModel):
    __tablename__ = "admin_actions"
    id = mapped_column(String, primary_key=True)
    admin_id = mapped_column(String, nullable=True)
    action = mapped_column(String, nullable=False)
    target_user_id = mapped_column(String, nullable=True)
    target_phone = mapped_column(String, nullable=True)
    details = mapped_column(JSON, default={})
    created_at = mapped_column(DateTime, default=datetime.datetime.utcnow)

    @staticmethod
    def log(admin_id, action, target_user_id=None, target_phone=None, details=None):
        with Session(bind=engine) as session:
            rec = AdminActions(
                id=None, admin_id=admin_id, action=action,
                target_user_id=target_user_id, target_phone=target_phone,
                details=details or {}, created_at=datetime.datetime.utcnow()
            )
            session.add(rec)
            session.commit()
