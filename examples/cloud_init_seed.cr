require "../src/silex"

# Exemple : produit `seed.img` (~100 Ko) utilisable comme NoCloud seed disk
# pour cloud-init. Le volume porte l'étiquette CIDATA (repérée automatiquement
# par le datasource NoCloud) et contient deux fichiers au nom exact attendu :
# `user-data` et `meta-data` (noms longs via entrées VFAT LFN).
#
# Usage :
#   crystal run examples/cloud_init_seed.cr
#   hdiutil attach -nomount seed.img        # macOS (vérification)
#   sudo mount -o loop seed.img /mnt        # Linux (vérification)

meta_data = <<-YAML
instance-id: iid-silex-example
local-hostname: cloud-init-silex
YAML

user_data = <<-CLOUD_CONFIG
#cloud-config
hostname: cloud-init-silex
users:
  - name: deploy
    shell: /bin/sh
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKey deploy@silex
CLOUD_CONFIG

image = Silex::FatImage.new(size_bytes: 128 * 1024, label: "CIDATA")
image.add_file("meta-data", meta_data)
image.add_file("user-data", user_data)

output_path = File.expand_path("seed.img", __DIR__)
File.write(output_path, image.to_slice)

puts "Image écrite : #{output_path} (#{File.size(output_path)} octets)"
puts "Étiquette    : #{image.label}"
puts "Fichiers     :"
puts "  - meta-data (#{meta_data.bytesize} octets)"
puts "  - user-data (#{user_data.bytesize} octets)"
