import logging
import logging
from ipaddress import ip_interface
from dataclasses import dataclass
import typing as t
import docker
from abc import ABC, abstractmethod
from docker.models.containers import Container
from docker.models.images import Image

class NodeImage(ABC):
    @abstractmethod
    def prepare_image(self, client: docker.DockerClient) -> Image:
        pass

class DockerImage(NodeImage):
    image_name: str

    def __init__(self, image_name: str):
        self.image_name = image_name

    @t.override
    def prepare_image(self, client: docker.DockerClient) -> Image:
        return client.images.get(self.image_name)

class DockerfileImage(NodeImage):
    context_path: str
    dockerfile_path: str
    build_args: str

    def __init__(self, context_path: str, dockerfile_path: t.Optional[str], build_args: t.Dict[str, str]):
        super().__init__();

        self.context_path = context_path
        self.dockerfile_path = dockerfile_path or f'{self.context_path}/Dockerfile'
        self.build_args = build_args

    @t.override
    def prepare_image(self, client: docker.DockerClient) -> Image:
        image, build_logs = client.images.build(path=self.context_path, dockerfile=self.dockerfile_path, buildargs=self.build_args)
        return image

class LocalDockerDriver:
    client: docker.DockerClient
    node_to_container_map: t.Dict[str, str]

    network: Network
    topology: Topology

    def __init__(self, topology: Topology):
        self.client = docker.DockerClient(base_url='unix:///var/run/docker.sock')
        self.api_client = docker.APIClient(base_url='unix:///var/run/docker.sock')
        self.node_to_container_map = {}
        self.topology = topology
        self.network = None

    def _run_container(self, image: Image, name: str) -> Container:
        logging.info(f"Starting container: {name}")
        container: Container = self.client.containers.run(
            image, 
            name=name, 
            command="tail -f /dev/null",
            detach=True,
            network=self.network.name,
            privileged=True,
        )
        return container

    def _start_node(self, node: Node):
        logging.info(f"Starting node: {node.name}")

        image = node.image.prepare_image(self.client)

        container = self._run_container(image, node.name)

        self.node_to_container_map[node.name] = container.id

    def _stop_node(self, node: Node):
        if node.name not in self.node_to_container_map:
            return

        container = self.client.containers.get(node.name)
        container.stop()
        container.remove()

    def _setup_gre(self, local_interface: Interface, remote_interface: Interface):
        local_container = self.client.containers.get(self.node_to_container_map[local_interface.node.name])
        remote_container = self.client.containers.get(self.node_to_container_map[remote_interface.node.name])

        local_details = self.api_client.inspect_container(local_container.id)
        remote_details = self.api_client.inspect_container(remote_container.id)

        tunnel_name = f'{local_interface.name}'
        remote_address = remote_details['NetworkSettings']['Networks'][self.network.name]['IPAddress']
        local_address = local_details['NetworkSettings']['Networks'][self.network.name]['IPAddress']

        command = f'ip tunnel add {tunnel_name} mode gre remote {remote_address} local {local_address} ttl 255'
        logging.debug(command)
        result = local_container.exec_run(command)

        print(result.output)

    def _setup_link(self, link: Link):
        logging.info(f'Linking nodes {link.a.node.name}<->{link.z.node.name}')
        self._setup_gre(link.a, link.z)
        self._setup_gre(link.z, link.a)

    def start(self):
        logging.info("Starting topology")
        self.network = self.client.networks.create(name=f'{self.topology.name}.net')
        for node in self.topology.nodes.values():
            self._start_node(node)

        for link in self.topology.links:
            self._setup_link(link)

    def stop(self):
        for node in self.topology.nodes.values():
            self._stop_node(node)
        self.network.remove()

@dataclass
class Node:
    image: NodeImage
    name: str

@dataclass
class Interface:
    name: str
    node: Node
    address: ip_interface

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
        a_intf: ip_interface,
        z_node: str,
        z_intf: ip_interface,
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

def main():
    logging.basicConfig(
        level=logging.INFO
    )
    logging.info("Starting")

    bird_image = DockerImage(image_name='bird-docker')
    
    topology = Topology(
        name="test-topo",
        nodes={
            'bird1': Node(
                image=bird_image,
                name='bird1'
            ),
            'bird2': Node(
                image=bird_image,
                name='bird2'
            ),
        },
        links=[]
    )
    topology.link_nodes(
        a_node='bird1',
        a_intf=ip_interface(address='192.168.0.2/30'),
        z_node='bird2',
        z_intf=ip_interface(address='192.168.0.3/30'),
    )
    driver = LocalDockerDriver(topology=topology)

    try:
        driver.start()
        logging.info("Finished setting up")
        logging.info("Stopping")
        driver.stop()
    except Exception as e:
        logging.exception(e)
        driver.stop()

if __name__ == "__main__":
    main()
