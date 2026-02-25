# server/src/models/phones.py
import datetime
from sqlalchemy import String, DateTime
from sqlalchemy.orm import mapped_column, Session
from .db import AbstractModel, engine

class Phones(AbstractModel):
    __tablename__ = "phones"
    id = mapped_column(String, primary_key=True)
    user_id = mapped_column(String, nullable=False)
    phone = mapped_column(String, nullable=False)
    status = mapped_column(String, nullable=False, default="pending_verification")
    created_at = mapped_column(DateTime, default=datetime.datetime.utcnow)
    verified_at = mapped_column(DateTime, nullable=True)

    @staticmethod
    def get_by_user(user_id):
        with Session(bind=engine) as session:
            return session.query(Phones).filter(Phones.user_id == user_id).first()
