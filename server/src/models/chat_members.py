# server/src/models/chat_members.py
import datetime
from sqlalchemy import String, DateTime
from sqlalchemy.orm import mapped_column, Session
from .db import AbstractModel, engine

class ChatMembers(AbstractModel):
    __tablename__ = "chat_members"
    id = mapped_column(String, primary_key=True)
    chat_id = mapped_column(String, nullable=False)
    user_id = mapped_column(String, nullable=False)
    joined_at = mapped_column(DateTime, default=datetime.datetime.utcnow)
    role = mapped_column(String, nullable=False, default='member')  # owner | moderator | member

    @staticmethod
    def add(chat_id, user_id, role='member'):
        with Session(bind=engine) as session:
            existing = session.query(ChatMembers).filter(
                ChatMembers.chat_id == chat_id, ChatMembers.user_id == user_id
            ).first()
            if existing:
                existing.role = role
                existing.joined_at = datetime.datetime.utcnow()
            else:
                rec = ChatMembers(chat_id=chat_id, user_id=user_id, role=role, joined_at=datetime.datetime.utcnow())
                session.add(rec)
            session.commit()
