import typing as t
import logging
import docker
from cluster_manager.configuration.models import Node
from cluster_manager.configuration.models import Topology
from cluster_manager.configuration.models import Interface
from cluster_manager.configuration.models import Link
from cluster_manager.drivers.base import BaseDriver
from docker.models.containers import Container
from docker.models.images import Image
from docker.models.networks import Network
from pyre_extensions import none_throws

class LocalDockerDriver(BaseDriver):
    client: docker.DockerClient
    node_to_container_map: t.Dict[str, str]

    network: Network
    topology: Topology

    def __init__(self, topology: Topology):
        self.client = docker.DockerClient(base_url='unix:///var/run/docker.sock')
        self.api_client = docker.APIClient(base_url='unix:///var/run/docker.sock')
        self.node_to_container_map = {}
        self.topology = topology
        self.network = self.client.networks.create(name=f'{self.topology.name}.net')

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
        for node in self.topology.nodes.values():
            self._start_node(node)

        for link in self.topology.links:
            self._setup_link(link)

    def stop(self):
        for node in self.topology.nodes.values():
            self._stop_node(node)
        self.network.remove()
