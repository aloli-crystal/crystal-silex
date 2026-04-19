require "../spec_helper"

describe Silex::FatImage do
  describe "#initialize" do
    it "refuse une taille inférieure à 32 Ko" do
      expect_raises(ArgumentError, /minimum/) do
        Silex::FatImage.new(size_bytes: 16 * 1024)
      end
    end

    it "refuse une taille non multiple de 512 octets" do
      expect_raises(ArgumentError, /multiple/) do
        Silex::FatImage.new(size_bytes: 32 * 1024 + 3)
      end
    end

    it "refuse une étiquette de plus de 11 caractères" do
      expect_raises(ArgumentError, /étiquette/) do
        Silex::FatImage.new(size_bytes: 64 * 1024, label: "ETIQUETTE_TROP_LONGUE")
      end
    end

    it "accepte une étiquette normale" do
      image = Silex::FatImage.new(size_bytes: 64 * 1024, label: "CIDATA")
      image.label.should eq("CIDATA")
    end
  end

  describe "#add_file" do
    it "refuse un nom vide" do
      image = Silex::FatImage.new(size_bytes: 64 * 1024)
      expect_raises(ArgumentError, /vide/) { image.add_file("", "x") }
    end

    it "refuse un nom de plus de 255 caractères" do
      image = Silex::FatImage.new(size_bytes: 64 * 1024)
      expect_raises(ArgumentError, /255/) { image.add_file("a" * 256, "x") }
    end

    it "refuse un nom contenant un séparateur de chemin" do
      image = Silex::FatImage.new(size_bytes: 64 * 1024)
      expect_raises(ArgumentError, /interdit/) { image.add_file("sub/file", "x") }
    end

    it "refuse deux fichiers de même nom" do
      image = Silex::FatImage.new(size_bytes: 64 * 1024)
      image.add_file("a.txt", "1")
      expect_raises(ArgumentError, /déjà/) { image.add_file("a.txt", "2") }
    end
  end

  describe "#to_slice" do
    it "produit une image de la taille demandée" do
      image = Silex::FatImage.new(size_bytes: 128 * 1024, label: "CIDATA")
      image.to_slice.size.should eq(128 * 1024)
    end

    it "écrit une signature de secteur d'amorçage valide (0x55AA)" do
      image = Silex::FatImage.new(size_bytes: 128 * 1024, label: "CIDATA")
      bytes = image.to_slice
      bytes[510].should eq(0x55_u8)
      bytes[511].should eq(0xAA_u8)
    end

    it "inscrit l'étiquette de volume dans le BPB" do
      image = Silex::FatImage.new(size_bytes: 128 * 1024, label: "CIDATA")
      bytes = image.to_slice
      String.new(bytes[43, 11]).rstrip(' ').should eq("CIDATA")
    end

    it "refuse un fichier plus gros que l'image" do
      image = Silex::FatImage.new(size_bytes: 64 * 1024, label: "TEST")
      huge = Bytes.new(200 * 1024, 0x41_u8)
      image.add_file("big.bin", huge)
      expect_raises(ArgumentError, /trop petite/) { image.to_slice }
    end
  end

  describe ".read (round-trip)" do
    it "retrouve l'étiquette de volume" do
      image = Silex::FatImage.new(size_bytes: 128 * 1024, label: "CIDATA")
      parsed = Silex::FatImage.read(image.to_slice)
      parsed.label.should eq("CIDATA")
    end

    it "retrouve un fichier 8.3 simple" do
      image = Silex::FatImage.new(size_bytes: 128 * 1024, label: "TEST")
      image.add_file("HELLO.TXT", "hello\n")
      parsed = Silex::FatImage.read(image.to_slice)
      parsed.files.size.should eq(1)
      parsed.files[0].name.should eq("HELLO.TXT")
      String.new(parsed.files[0].content).should eq("hello\n")
    end

    it "retrouve deux fichiers avec noms longs cloud-init" do
      image = Silex::FatImage.new(size_bytes: 128 * 1024, label: "CIDATA")
      meta = "instance-id: iid-local01\nlocal-hostname: test\n"
      user = "#cloud-config\nssh_authorized_keys:\n  - ssh-ed25519 AAAA\n"
      image.add_file("meta-data", meta)
      image.add_file("user-data", user)

      parsed = Silex::FatImage.read(image.to_slice)
      parsed.label.should eq("CIDATA")
      names = parsed.files.map(&.name).sort
      names.should eq(["meta-data", "user-data"])

      by_name = parsed.files.index_by(&.name)
      String.new(by_name["meta-data"].content).should eq(meta)
      String.new(by_name["user-data"].content).should eq(user)
    end

    it "supporte un contenu binaire qui s'étend sur plusieurs clusters" do
      image = Silex::FatImage.new(size_bytes: 256 * 1024, label: "MULTI")
      blob = Bytes.new(8 * 1024) { |i| (i % 251).to_u8 }
      image.add_file("blob.bin", blob)

      parsed = Silex::FatImage.read(image.to_slice)
      parsed.files.size.should eq(1)
      parsed.files[0].name.should eq("blob.bin")
      parsed.files[0].content.should eq(blob)
    end

    it "gère un contenu vide" do
      image = Silex::FatImage.new(size_bytes: 64 * 1024, label: "EMPTY")
      image.add_file("empty.txt", "")
      parsed = Silex::FatImage.read(image.to_slice)
      parsed.files.size.should eq(1)
      parsed.files[0].content.size.should eq(0)
    end
  end
end
