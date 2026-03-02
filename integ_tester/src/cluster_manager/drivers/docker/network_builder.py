import logging
import os
from cluster_manager.drivers.docker.local_network_spec import LocalNodeInfo
from cluster_manager.drivers.docker.local_network_spec import LocalNetworkInfo
from cluster_manager.drivers.docker.local_network_spec import LocalDockerNetworkSpec
from cluster_manager.drivers.docker.local_network_spec import SPEC_TYPE
from cluster_manager.drivers.running_network_spec import Spec
import logging
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

class LocalNetworkBuilder:
    client: DockerClient
    api_client: APIClient

    node_to_container_map: t.Dict[str, str]

    topology: Topology
    network: Network

    def __init__(self, docker_client: DockerClient, docker_api_client: APIClient, topology: Topology):
        self.client = docker_client
        self.api_client = docker_api_client

        self.node_to_container_map = {}

        self.topology = topology
        self.network = self.client.networks.create(name=f'{get_random_string(5)}-{self.topology.name}.net')

    def start_network(self) -> Spec:
        for node in self.topology.nodes.values():
            self._start_node(node)

        for link in self.topology.links:
            self._setup_link(link)

        return Spec(
            driver_type=SPEC_TYPE,
            spec_data=LocalDockerNetworkSpec(
                network=LocalNetworkInfo(
                    network_name=none_throws(self.network.name),
                    network_id=none_throws(self.network.id)
                ),
                nodes=[LocalNodeInfo(
                    node_name=item[0],
                    container_id=item[1]
                ) for item in self.node_to_container_map.items()],
            )
        )

    @staticmethod
    def get_container_volume_location(container_name: str) -> str:
        return f'/tmp/integ-tester/containers/{container_name}'

    def _run_container(self, image: Image, name: str) -> Container:
        logging.info(f"Starting container: {name}")
        
        container: Container = self.client.containers.run(
            image, 
            command=['tail', '-f', '/dev/null'],
            name=name, 
            detach=True,
            network=self.network.name,
            privileged=True,
        )
        return container

    def _start_node(self, node: Node):
        logging.info(f"Starting node: {node.name}")

        image = node.image.prepare_image(self.client)

        container = self._run_container(image, node.name)

        self.node_to_container_map[node.name] = none_throws(container.id)

    def _stop_node(self, node: Node):
        if node.name not in self.node_to_container_map:
            return

        container = self.client.containers.get(node.name)
        container.stop()
        container.remove()

    def _setup_gre(self, local_interface: Interface, remote_interface: Interface):
        local_container = self.client.containers.get(self.node_to_container_map[local_interface.node.name])
        remote_container = self.client.containers.get(self.node_to_container_map[remote_interface.node.name])

        local_details = self.api_client.inspect_container(none_throws(local_container.id))
        remote_details = self.api_client.inspect_container(none_throws(remote_container.id))

        tunnel_name = f'{local_interface.name}'
        remote_address = remote_details['NetworkSettings']['Networks'][self.network.name]['IPAddress']
        local_address = local_details['NetworkSettings']['Networks'][self.network.name]['IPAddress']

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

    def _setup_link(self, link: Link):
        logging.info(f'Linking nodes {link.a.node.name}<->{link.z.node.name}')
        self._setup_gre(link.a, link.z)
        self._setup_gre(link.z, link.a)
