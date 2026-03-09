from pyre_extensions import JSON
from typing import TypeAlias
from typing import Type
from typing import Mapping
import io
from typing import List
import ipaddress as ip
import typing as t
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, Dict

IpInterface = ip.IPv4Interface | ip.IPv6Interface

@dataclass
class Node:
    image_name: str
    name: str

    data: Dict[str, Any]

    def set(self, key: str, value: Any) -> Any:
        self.data[key] = value

    def get(self, key: str) -> Any:
        return self.data[key]

@dataclass
class Interface:
    name: str
    node: Node
    address: IpInterface

@dataclass
class Link:
    a: Interface
    z: Interface

@dataclass
class Topology:
    name: str
    nodes: t.Dict[str, Node]
    links: t.List[Link]

    def link_nodes(
        self,
        a_node: str,
        a_intf: IpInterface,
        z_node: str,
        z_intf: IpInterface,
    ):
        self.links.append(Link(
            a = Interface(
                name=f'{a_node}{z_node}',
                node=self.nodes[a_node],
                address=a_intf,
            ),
            z = Interface(
                name=f'{z_node}{a_node}',
                node=self.nodes[z_node],
                address=z_intf,
            ),
        ))

class Service(ABC):
    node: Node

    def __init__(self, node: Node):
        self.node = node

    @classmethod
    def match_node(cls, node: Node) -> bool:
        return False

    @abstractmethod
    def get_files(self) -> Mapping[str, io.IOBase]:
        pass

    @abstractmethod
    def get_start_command(self) -> str | List[str]:
        pass

class TestingConfiguration(ABC):
    @property
    @abstractmethod
    def topology(self) -> Topology:
        pass

    @abstractmethod
    def get_services(self) -> List[Type[Service]]:
        pass

    @classmethod
    @abstractmethod
    def deserialize(cls, data: Dict[str, JSON]) -> TestingConfiguration:
        pass

    @abstractmethod
    def serialize(self) -> Dict[str, JSON]:
        pass
