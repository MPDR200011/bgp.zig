from typing import Any
from pydantic import BaseModel


class Spec(BaseModel):
    driver_type: str
    spec_data: Any
