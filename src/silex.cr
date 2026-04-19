require "./silex/version"
require "./silex/fat_image"

# Silex — writer Crystal pur pour images FAT12 minimales.
#
# Usage principal : générer des seed disks cloud-init NoCloud sans dépendance
# à un outil externe (`mkfs.vfat`, `xorriso`, `hdiutil`, etc.).
#
# ```
# require "silex"
#
# image = Silex::FatImage.new(size_bytes: 128 * 1024, label: "CIDATA")
# image.add_file("meta-data", "instance-id: iid-local01\nlocal-hostname: test\n")
# image.add_file("user-data", "#cloud-config\n")
# File.write("seed.img", image.to_slice)
# ```
module Silex
end
