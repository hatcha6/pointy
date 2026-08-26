"""Render the offline Compose file a release bundle ships.

release.yml does this with `yq ... | sed 's/!!merge //g'`: drop the `build:`
sections (a shop has no source tree to build from) and flatten the YAML anchors.
This is the same transformation in PyYAML, so the rehearsal's bundles are laid
out the way real ones are — including the fact that a bundle's compose file is
NOT byte-identical to the repo's.

    python3 compose-offline.py <in.yml> <out.yml>
"""

import sys

import yaml

source, destination = sys.argv[1], sys.argv[2]

with open(source) as handle:
    document = yaml.safe_load(handle)

for service in document.get("services", {}).values():
    service.pop("build", None)

with open(destination, "w") as handle:
    yaml.safe_dump(document, handle, default_flow_style=False, sort_keys=False, width=4096)

# The bundle must never carry a build: section — a shop would try to build from
# a source tree it does not have. release.yml asserts this too.
with open(destination) as handle:
    if any(line.strip().startswith("build:") for line in handle):
        sys.exit("build: section survived in the offline compose")
