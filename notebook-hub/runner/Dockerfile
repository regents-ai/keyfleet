# check=skip=InvalidDefaultArgInFrom
# The runner machine image: marimohub's own sandbox image at the pinned commit
# (marimo 0.25.2, its library set and notebook bridge), plus the helper the hub
# drives it through and the kernel's IPv6 relay. Build with scripts/build-images.sh.
# SANDBOX_IMAGE has no default on purpose: scripts/build-images.sh always passes it.
ARG SANDBOX_IMAGE
FROM ${SANDBOX_IMAGE}

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends socat \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 helper.py entrypoint.sh /opt/runner/

# The helper starts as root and runs everything notebook-side as appuser.
WORKDIR /workspace
CMD ["/opt/runner/entrypoint.sh"]
