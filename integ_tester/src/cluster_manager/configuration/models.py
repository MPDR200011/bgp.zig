from typing import List
from typing import Type
from typing import Dict
from abc import abstractmethod
import ipaddress as ip
import typing as t
from dataclasses import dataclass

from cluster_manager.configuration.nodes import Node

IpInterface = ip.IPv4Interface | ip.IPv6Interface

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


class TestingConfiguration:

    _node_types: Dict[str, Type[Node]]

    def __init__(self, node_types: List[Type[Node]]):
        self._node_types = {
            nt.__name__: nt for nt in node_types
        }

    @property
    @abstractmethod
    def topology(self) -> Topology:
        raise NotImplementedError()

