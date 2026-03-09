import logging
import traceback
from pathlib import Path

import click
from dotenv import load_dotenv

from cluster_manager.configuration.concrete.my_config import MyTestingConfiguration
from cluster_manager.drivers.docker.local_docker_helper import LocalDockerHelper
from cluster_manager.drivers.running_network_spec import Spec


@click.group()
def main_command():
    pass

@click.command
def start_cluster():
    config = MyTestingConfiguration()
    helper = LocalDockerHelper()

    driver_data = helper.build_network(config)

    try:
        driver = helper.get_driver(driver_data)
        network_services = config.get_services()

        for node in config.topology.nodes.values():
            for service in network_services:
                if not service.match_node(node):
                    continue

                service_instance = service(node)

                files_to_install = service_instance.get_files()
                for path, contents in files_to_install.items():
                    driver.install_file(node, Path(path), contents)

                result = driver.run_cmd(node, service_instance.get_start_command(), wait=True)
                print(result.output)

        spec = Spec(
            # test_config=config,
            driver_data=driver_data
        )
        with open('/tmp/network_spec.json', 'w') as f:
            f.write(spec.model_dump_json(indent=2))
    except Exception:
        logging.error(f'Error occurred: {traceback.format_exc()}')
        helper.teardown_network(driver_data)

@click.command
def stop_cluster():
    with open('/tmp/network_spec.json') as f:
        spec = Spec.model_validate_json(f.read())

    LocalDockerHelper().teardown_network(spec.driver_data)


def build_cli():
    main_command.add_command(start_cluster)
    main_command.add_command(stop_cluster)

def main():
    load_dotenv()
    logging.basicConfig(
        level=logging.INFO
    )
    logging.info("Starting CLI")

    build_cli()
    main_command()

