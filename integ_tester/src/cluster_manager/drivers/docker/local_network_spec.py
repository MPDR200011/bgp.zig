from typing import List
from pydantic import BaseModel

SPEC_TYPE = "LocalNetworkType"

class LocalNetworkInfo(BaseModel):
    network_name: str
    network_id: str

class LocalNodeInfo(BaseModel):
    node_name: str
    container_id: str

class LocalDockerNetworkSpec(BaseModel):
    network: LocalNetworkInfo
    nodes: List[LocalNodeInfo]
