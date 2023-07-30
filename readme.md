## Traefik with SSL for local development

simply download traefik.sh and run it

what script will do:
- generate root certificate
- generate 2nd level domain certificate
- generate docker-compose.yml
- generate traefik.yml config
- generate dynamic_config.yml config
- create docker `web` network
- docker-compose up-d