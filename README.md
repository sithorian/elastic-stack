# SIMPLE ELASTICSEARCH STACK INSTALLER
Full stack with lots of features written in bash

## DISCLAIMER
This is still in testing! I am not a professional coder so expect some typos and not-efficient approaches so don't blame me :)

It is currently tested on Debian/Ubuntu and Centos/Redhat. Alpine Linux support will be added too.

## MAIN PURPOSE
The main goal is to create a backend datalake for Vectra Stream Platform during test/dev phases, but since this is an optional feature, you can use it for any other purposes which needs a serious ES cluster as a backend.
I have tried to make Elasticsearch Cluster deployment as possible as simple and flexible. Therefor I have decided to use docker environment with some additional flavors.
The challenges during a standart ES Cluster deployment are
  - System tunings
  - Memory assignments
  - Storage issues
  - Planning
  - Performance
  - Security

## COMPONENTS
Several components have been used in this stack.
  - Fluent-Bit (instead of Logstash)
  - HAProxy (load balancing and reverse proxy)
  - Dozzle (container monitoring)
  - Portainer (container management)
  - Kibana
  - Elasticsearch Nodes

## STACK TOPOLOGY

![topology](./screenshots/stack-topology.svg)

When you run the script, everything is quite straightforward and you can navigate yourself through menus.

## SCREENSHOTS

### Main Menu
![main-menu](./screenshots/main-menu.png)

### OS/System Menu
![os-menu](./screenshots/os_system-menu.png)

### Containers Menu
![container-menu](./screenshots/container-menu.png)

### Elasticsearch Menu
![elastic-menu](./screenshots/elastic-menu.png)

### Vectra Related
![vectra-menu](./screenshots/vectra-menu.png)