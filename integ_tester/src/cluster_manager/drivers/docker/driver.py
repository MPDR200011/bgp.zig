from cluster_manager.drivers.docker.local_network_spec import LocalDockerNetworkSpec
import logging

import docker

from cluster_manager.configuration.models import Topology
from cluster_manager.drivers.base import BaseDriver
from cluster_manager.drivers.docker.network_builder import LocalNetworkBuilder
from cluster_manager.drivers.running_network_spec import Spec


class LocalDockerDriver(BaseDriver):
    client: docker.DockerClient
    api_client: docker.APIClient

    def __init__(self):
        self.client = docker.DockerClient(base_url='unix:///var/run/docker.sock')
        self.api_client = docker.APIClient(base_url='unix:///var/run/docker.sock')

    def start(self, topology: Topology) -> Spec:
        logging.info("Starting network")

        builder = LocalNetworkBuilder(self.client, self.api_client, topology)
        return builder.start_network()

    def stop(self, spec: LocalDockerNetworkSpec):
        for node in spec.nodes:
            container = self.client.containers.get(node.container_id)
            container.stop()
            container.remove()

        network = self.client.networks.get(spec.network.network_id)
        network.remove()
