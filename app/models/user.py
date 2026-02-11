# app/models/user.py
# Модель пользователя: phone, hashed_password, role, blacklisted.
from sqlalchemy import Column, Integer, String, Boolean, DateTime, Enum
from datetime import datetime
from app.db.base import Base
import enum

class RoleEnum(str, enum.Enum):
    client = "client"
    worker = "worker"
    admin = "admin"
    leader = "leader"

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    phone = Column(String, unique=True, index=True, nullable=False)
    hashed_password = Column(String, nullable=True)
    full_name = Column(String, nullable=True)
    role = Column(Enum(RoleEnum), default=RoleEnum.client)
    created_at = Column(DateTime, default=datetime.utcnow)
    blacklisted = Column(Boolean, default=False)
