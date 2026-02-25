# server/src/models/chats.py
import datetime
from sqlalchemy import String, Text, JSON
from sqlalchemy.orm import mapped_column, Session
from .db import AbstractModel, engine

class Chats(AbstractModel):
    __tablename__ = "chats"
    id = mapped_column(String, primary_key=True)
    title = mapped_column(Text, nullable=True)
    type = mapped_column(String, default='public')  # public | private
    created_by = mapped_column(String, nullable=True)
    settings = mapped_column(JSON, default={})
    created_at = mapped_column(DateTime, default=datetime.datetime.utcnow)
    updated_at = mapped_column(DateTime, nullable=True)

    @staticmethod
    def create(title, created_by=None, type='public'):
        with Session(bind=engine) as session:
            chat = Chats(title=title, created_by=created_by, type=type, created_at=datetime.datetime.utcnow())
            session.add(chat)
            session.commit()
            return chat
