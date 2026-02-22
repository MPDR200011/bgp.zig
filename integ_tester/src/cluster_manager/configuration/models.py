from docker.models.images import Image
from docker import DockerClient
import docker
import ipaddress as ip
from abc import abstractmethod
import abc
import typing as t
from dataclasses import dataclass

IpInterface = ip.IPv4Interface | ip.IPv6Interface

class NodeImage(abc.ABC):
    @abstractmethod
    def prepare_image(self, client: DockerClient) -> Image:
        pass

class DockerImage(NodeImage):
    image_name: str

    def __init__(self, image_name: str):
        self.image_name = image_name

    @t.override
    def prepare_image(self, client: docker.DockerClient) -> Image:
        return client.images.get(self.image_name)

@dataclass
class Node:
    image: NodeImage
    name: str

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
