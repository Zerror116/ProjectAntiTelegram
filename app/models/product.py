# app/models/product.py
# Модели для черновиков товаров (ProductDraft) и записей канала (ChannelPost).
from sqlalchemy import Column, Integer, String, Float, Boolean, DateTime, ForeignKey, Text
from sqlalchemy.orm import relationship
from datetime import datetime
from app.db.base import Base

class ProductDraft(Base):
    __tablename__ = "product_drafts"

    id = Column(Integer, primary_key=True, index=True)
    creator_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    title = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    price = Column(Float, nullable=False)
    quantity = Column(Integer, default=1)
    image_path = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    published = Column(Boolean, default=False)
    creator = relationship("User", backref="drafts")

class ChannelPost(Base):
    __tablename__ = "channel_posts"

    id = Column(Integer, primary_key=True, index=True)
    draft_id = Column(Integer, ForeignKey("product_drafts.id"), nullable=False)
    posted_at = Column(DateTime, default=datetime.utcnow)
    draft = relationship("ProductDraft")
