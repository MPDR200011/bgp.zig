import logging
import traceback
import logging
from dataclasses import dataclass
import string
import random
import typing as t

from docker import APIClient, DockerClient
from docker.models.containers import Container
from docker.models.images import Image
from docker.models.networks import Network
from pyre_extensions import none_throws

from cluster_manager.configuration.models import Interface, Link, Node, Topology

def get_random_string(length: int) -> str:
    result_str = ''.join(random.choice(string.ascii_lowercase) for i in range(length))
    return result_str

@dataclass
class LocalNetwork:
    network: Network
    containers: t.Dict[str, Container]

class LocalNetworkBuilder:
    client: DockerClient
    api_client: APIClient

    node_to_container_map: t.Dict[str, Container]

    topology: Topology

    def __init__(self, docker_client: DockerClient, docker_api_client: APIClient, topology: Topology):
        self.client = docker_client
        self.api_client = docker_api_client
        self.node_to_container_map = {}
        self.topology = topology

    @staticmethod
    def teardown_network(network: LocalNetwork):
        for container in network.containers.values():
            logging.info(f'Stopping container {container.name}')
            container.stop()
            container.remove()

        network.network.remove()

    def start_network(self) -> LocalNetwork:
        network = self.client.networks.create(name=f'{get_random_string(5)}-{self.topology.name}.net')
        try:
            for node in self.topology.nodes.values():
                container = self._start_node(node, network)
                self.node_to_container_map[node.name] = container

            for link in self.topology.links:
                self._setup_link(network, link)

            return LocalNetwork(
                network=network,
                containers=self.node_to_container_map
            )
        except Exception as e:
            logging.error(f'Error starting network: ${traceback.format_exc()}')
            logging.info('Rolling back creation')
            for container in self.node_to_container_map.values():
                container.stop()
                container.remove()

            network.remove()

            raise e

    @staticmethod
    def get_container_volume_location(container_name: str) -> str:
        return f'/tmp/integ-tester/containers/{container_name}'

    def _run_container(self, image: Image, name: str, network: Network) -> Container:
        logging.info(f"Starting container: {name}")
        
        container: Container = self.client.containers.run(
            image, 
            command=['tail', '-f', '/dev/null'],
            name=name, 
            detach=True,
            network=network.name,
            privileged=True,
            init=True
        )
        return container

    def _start_node(self, node: Node, network: Network) -> Container:
        logging.info(f"Starting node: {node.name}")

        image = self.client.images.get(node.image_name)

        return self._run_container(image, node.name, network)

    def _stop_node(self, node: Node):
        if node.name not in self.node_to_container_map:
            return

        container = self.client.containers.get(node.name)
        container.stop()
        container.remove()

    def _setup_gre(self, network: Network, local_interface: Interface, remote_interface: Interface):
        local_container = self.node_to_container_map[local_interface.node.name]
        remote_container = self.node_to_container_map[remote_interface.node.name]

        local_details = self.api_client.inspect_container(none_throws(local_container.id))
        remote_details = self.api_client.inspect_container(none_throws(remote_container.id))

        tunnel_name = f'{local_interface.name}'
        remote_address = remote_details['NetworkSettings']['Networks'][network.name]['IPAddress']
        local_address = local_details['NetworkSettings']['Networks'][network.name]['IPAddress']

        logging.debug(f"{tunnel_name}: creating")
        command = f'ip tunnel add {tunnel_name} mode gre remote {remote_address} local {local_address} ttl 255'
        logging.debug(command)
        result = local_container.exec_run(command)
        print(result.output)

        logging.debug(f"{tunnel_name}: assigning address")
        result = local_container.exec_run(f'ip addr add {local_interface.address} dev {tunnel_name}')
        print(result.output)

        logging.debug(f"{tunnel_name}: assigning setting up")
        result = local_container.exec_run(f'ip link set {tunnel_name} up')
        print(result.output)

    def _setup_link(self, network: Network, link: Link):
        logging.info(f'Linking nodes {link.a.node.name}<->{link.z.node.name}')
        self._setup_gre(network, link.a, link.z)
        self._setup_gre(network, link.z, link.a)
