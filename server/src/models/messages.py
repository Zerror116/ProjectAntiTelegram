# server/src/models/messages.py
import datetime
from sqlalchemy import String, Text, JSON
from sqlalchemy.orm import mapped_column, Session
from .db import AbstractModel, engine

class Messages(AbstractModel):
    __tablename__ = "messages"
    id = mapped_column(String, primary_key=True)
    chat_id = mapped_column(String, nullable=False)
    sender_id = mapped_column(String, nullable=True)
    text = mapped_column(Text, nullable=False)
    meta = mapped_column(JSON, default={})
    created_at = mapped_column(DateTime, default=datetime.datetime.utcnow)

    @staticmethod
    def create(chat_id, sender_id, text, meta=None):
        with Session(bind=engine) as session:
            rec = Messages(chat_id=chat_id, sender_id=sender_id, text=text, meta=meta or {}, created_at=datetime.datetime.utcnow())
            session.add(rec)
            session.commit()
            return rec
