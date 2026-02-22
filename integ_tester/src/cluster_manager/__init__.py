from cluster_manager.drivers.docker.driver import LocalDockerDriver
from cluster_manager.configuration.models import Node
from cluster_manager.configuration.models import Topology
from cluster_manager.configuration.models import DockerImage
import logging
import click
import ipaddress as ip

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
    a_intf=ip.ip_interface(address='192.168.0.2/30'),
    z_node='bird2',
    z_intf=ip.ip_interface(address='192.168.0.3/30'),
)

@click.group()
def main_command():
    pass

@click.command
def start_cluster():
    driver = LocalDockerDriver(topology=topology)
    driver.start()

@click.command
def stop_cluster():
    driver = LocalDockerDriver(topology=topology)
    driver.stop()

def build_cli():
    main_command.add_command(start_cluster)
    main_command.add_command(stop_cluster)

def main():
    logging.basicConfig(
        level=logging.INFO
    )
    logging.info("Starting")

    build_cli()
    main_command()

