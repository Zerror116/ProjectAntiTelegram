# server/src/models/users.py
import datetime
from sqlalchemy import String, Boolean, DateTime
from sqlalchemy.orm import mapped_column, Session
from .db import AbstractModel, engine

class Users(AbstractModel):
    __tablename__ = "users"
    id = mapped_column(String, primary_key=True)  # UUID as text
    email = mapped_column(String, unique=True, nullable=True)
    password_hash = mapped_column(String, nullable=True)
    role = mapped_column(String, nullable=False, default="client")  # client | creator | admin
    name = mapped_column(String, nullable=True)
    is_active = mapped_column(Boolean, default=True)
    created_at = mapped_column(DateTime, default=datetime.datetime.utcnow)
    updated_at = mapped_column(DateTime, default=datetime.datetime.utcnow)

    @staticmethod
    def get_by_id(user_id):
        with Session(bind=engine) as session:
            return session.query(Users).filter(Users.id == user_id).first()

    @staticmethod
    def get_by_email(email):
        with Session(bind=engine) as session:
            return session.query(Users).filter(Users.email == email).first()

    @staticmethod
    def set_role(user_id, role):
        with Session(bind=engine) as session:
            u = session.query(Users).filter(Users.id == user_id).first()
            if not u:
                return False
            u.role = role
            u.updated_at = datetime.datetime.utcnow()
            session.commit()
            return True
