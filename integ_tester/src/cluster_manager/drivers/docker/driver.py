import logging

import docker

from cluster_manager.configuration.models import Topology
from cluster_manager.drivers.base import BaseDriver
from cluster_manager.drivers.docker.network_builder import LocalNetworkBuilder


class LocalDockerDriver(BaseDriver):
    client: docker.DockerClient
    api_client: docker.APIClient

    def __init__(self):
        self.client = docker.DockerClient(base_url='unix:///var/run/docker.sock')
        self.api_client = docker.APIClient(base_url='unix:///var/run/docker.sock')

    def start(self, topology: Topology):
        logging.info("Starting network")

        builder = LocalNetworkBuilder(self.client, self.api_client, topology)
        builder.start_network()

    def stop(self):
        pass
        # TODO 
        # for node in self.topology.nodes.values():
        #     self._stop_node(node)
        # self.network.remove()
