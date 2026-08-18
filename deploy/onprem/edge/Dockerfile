# syntax=docker/dockerfile:1
#
# Pointy's LAN front door: nginx plus the config that lets a backend be swapped
# under live traffic (see pointy-edge.conf).
#
# The config is baked in rather than bind-mounted for two reasons. It reaches a
# shop the same way everything else does — through the image tars in the release
# bundle — so a deployment upgrading from before the front door existed cannot
# end up with an nginx that has no configuration. And the image tag is bumped by
# hand (pointy-edge:1, :2, …), NOT per release, so this container keeps the LAN
# port through every application update without being recreated. That stability
# is the entire point of the front door: recreating it is the outage it exists
# to avoid.
FROM nginx:1.29-alpine
RUN rm -f /etc/nginx/conf.d/default.conf && mkdir -p /etc/nginx/conf.d/active
COPY deploy/onprem/edge/pointy-edge.conf /etc/nginx/conf.d/pointy-edge.conf
EXPOSE 8000
