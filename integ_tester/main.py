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

    def __init__(self):
        self.client = docker.DockerClient(base_url='unix:///var/run/docker.sock')
        self.node_to_container_map = {}

    def _run_container(self, image: docker.Images, name: str) -> Container:
        container: Container = self.client.containers.run(image, name=name, detach=True)
        return container

    def start_node(self, node: Node):
        image = node.image.prepare_image(self.client)

        container = self._run_container(image, node.name)

        self.node_to_container_map[node.name] = container.id

    def stop_node(self, node: Node):
        if node.name not in self.node_to_container_map:
            raise ValueError(f'node not started: {node.name}')

        container = self.client.containers.get(node.name)
        container.stop()
        container.remove()


@dataclass
class Node:
    image: NodeImage
    name: str


def main():
    driver = LocalDockerDriver()

    node = Node(
        image=DockerfileImage('../', './integ_tester/bgpz/Dockerfile', build_args={
            'BINARY_LOCATION': './zig-out/bin/bgpz'
        }),
        name='bgpz-container'
    )

    driver.start_node(node)
    driver.stop_node(node)


if __name__ == "__main__":
    main()
