module Silex
  # Writer FAT12 pur Crystal.
  #
  # Construit une image de système de fichiers FAT12 en mémoire, utilisable pour
  # générer des seed disks cloud-init NoCloud (user-data, meta-data) sans outil
  # externe.
  #
  # Le plan disque suit la spécification Microsoft FAT (ECMA-107) :
  #
  # ```
  # +-------------------+
  # | Boot sector (BPB) |  1 secteur (512 o)
  # +-------------------+
  # | FAT #1            |  sectors_per_fat
  # +-------------------+
  # | FAT #2            |  sectors_per_fat  (copie)
  # +-------------------+
  # | Root directory    |  root_dir_sectors (taille fixe)
  # +-------------------+
  # | Data area         |  clusters de sectors_per_cluster secteurs
  # +-------------------+
  # ```
  #
  # Les noms de fichiers longs (> 8.3) sont stockés via des entrées VFAT LFN
  # précédant l'entrée 8.3 classique. Indispensable pour que cloud-init lise
  # `user-data` et `meta-data` (9 caractères chacun, hors 8.3).
  class FatImage
    # Taille d'un secteur en octets. FAT12 tolère 512, 1024, 2048, 4096 ;
    # Silex s'en tient à 512 pour la simplicité et la compatibilité maximale.
    SECTOR_SIZE = 512

    # Entrée de répertoire sur disque : toujours 32 octets (FAT ou VFAT).
    DIR_ENTRY_SIZE = 32

    # Attributs FAT.
    ATTR_READ_ONLY = 0x01_u8
    ATTR_HIDDEN    = 0x02_u8
    ATTR_SYSTEM    = 0x04_u8
    ATTR_VOLUME_ID = 0x08_u8
    ATTR_DIRECTORY = 0x10_u8
    ATTR_ARCHIVE   = 0x20_u8
    ATTR_LFN       = 0x0F_u8 # READ_ONLY | HIDDEN | SYSTEM | VOLUME_ID

    # Taille minimale acceptée (32 KB). En dessous, FAT12 n'a plus vraiment de
    # sens et les implémentations divergent.
    MIN_SIZE_BYTES = 32 * 1024

    # Taille maximale : FAT12 ne gère que 4084 clusters utiles.
    # Avec sectors_per_cluster = 1 et secteur 512 octets, ~2 Mo.
    # Avec sectors_per_cluster = 8, ~16 Mo. Silex accepte jusqu'à 16 Mo.
    MAX_SIZE_BYTES = 16 * 1024 * 1024

    # Longueur max d'un nom de fichier. 255 = limite VFAT LFN.
    MAX_FILENAME_LENGTH = 255

    # Fichier en attente d'écriture dans l'image.
    private record PendingFile, name : String, content : Bytes

    # Fichier lu depuis une image existante.
    record File, name : String, content : Bytes

    getter size_bytes : Int32
    getter label : String
    getter files : Array(File)

    @pending : Array(PendingFile)
    @sectors_per_cluster : Int32
    @reserved_sectors : Int32
    @num_fats : Int32
    @root_entries : Int32
    @total_sectors : Int32
    @sectors_per_fat : Int32
    @media : UInt8

    # Crée une nouvelle image vide.
    #
    # * *size_bytes* — taille totale de l'image (doit être multiple de 512).
    # * *label* — étiquette de volume (max 11 caractères ASCII, en majuscules
    #   de préférence). `"CIDATA"` pour cloud-init NoCloud.
    def initialize(@size_bytes : Int32, label : String = "NO NAME")
      raise ArgumentError.new("taille #{@size_bytes} < minimum #{MIN_SIZE_BYTES} octets") if @size_bytes < MIN_SIZE_BYTES
      raise ArgumentError.new("taille #{@size_bytes} > maximum #{MAX_SIZE_BYTES} octets") if @size_bytes > MAX_SIZE_BYTES
      raise ArgumentError.new("taille #{@size_bytes} non multiple de #{SECTOR_SIZE}") unless @size_bytes.divisible_by?(SECTOR_SIZE)

      @label = normalize_label(label)
      @pending = [] of PendingFile
      @files = [] of File

      @total_sectors = @size_bytes // SECTOR_SIZE
      @reserved_sectors = 1
      @num_fats = 2
      @media = 0xF8_u8 # disque fixe (non amovible)

      # Choix de sectors_per_cluster : 1 pour les petites images,
      # augmenté au besoin pour rester sous 4084 clusters (limite FAT12).
      @sectors_per_cluster = pick_sectors_per_cluster
      @root_entries = 112 # 7 secteurs de répertoire racine (112 * 32 / 512)
      @sectors_per_fat = compute_sectors_per_fat
    end

    # Ajoute un fichier. Le contenu peut être une `String` ou des `Bytes`.
    def add_file(name : String, content : String) : Nil
      add_file(name, content.to_slice)
    end

    def add_file(name : String, content : Bytes) : Nil
      raise ArgumentError.new("nom vide") if name.empty?
      raise ArgumentError.new("nom > #{MAX_FILENAME_LENGTH} caractères") if name.size > MAX_FILENAME_LENGTH
      raise ArgumentError.new("nom interdit : #{name.inspect}") if name.includes?('/') || name.includes?('\\') || name.includes?('\0')
      if @pending.any? { |f| f.name == name }
        raise ArgumentError.new("fichier #{name.inspect} déjà ajouté")
      end
      # On copie le contenu pour isoler l'image des mutations côté appelant.
      @pending << PendingFile.new(name, content.dup)
    end

    # Sérialise l'image complète en `Bytes` (Slice(UInt8)).
    def to_slice : Bytes
      buffer = Bytes.new(@size_bytes, 0_u8)

      write_boot_sector(buffer)

      # Allocation des clusters et calcul du layout.
      root_dir_sector = @reserved_sectors + @num_fats * @sectors_per_fat
      root_dir_sectors = (@root_entries * DIR_ENTRY_SIZE) // SECTOR_SIZE
      data_start_sector = root_dir_sector + root_dir_sectors
      bytes_per_cluster = @sectors_per_cluster * SECTOR_SIZE
      total_data_sectors = @total_sectors - data_start_sector
      total_clusters = total_data_sectors // @sectors_per_cluster

      fat = Array(UInt16).new(total_clusters + 2, 0_u16)
      # Entrées réservées : cluster 0 contient l'octet média + 0xFFF, cluster 1 = 0xFFF.
      fat[0] = (0x0F00_u16 | @media.to_u16)
      fat[1] = 0x0FFF_u16

      dir_entries = [] of Bytes
      # Entrée étiquette de volume en tête du répertoire racine.
      dir_entries << volume_label_entry

      used_names = Set(String).new
      next_free_cluster = 2

      @pending.each do |pending|
        content = pending.content
        file_clusters = content.size == 0 ? 0 : ((content.size + bytes_per_cluster - 1) // bytes_per_cluster)

        if next_free_cluster + file_clusters - 1 > total_clusters + 1
          raise ArgumentError.new("image trop petite pour contenir #{pending.name.inspect} (#{content.size} octets)")
        end

        first_cluster = file_clusters == 0 ? 0 : next_free_cluster

        # Chaînage FAT : chaque cluster pointe vers le suivant, le dernier à 0xFFF.
        file_clusters.times do |i|
          cluster = next_free_cluster + i
          if i == file_clusters - 1
            fat[cluster] = 0x0FFF_u16
          else
            fat[cluster] = (cluster + 1).to_u16
          end
        end

        # Copie du contenu dans la zone data.
        if file_clusters > 0
          offset = (data_start_sector + (first_cluster - 2) * @sectors_per_cluster) * SECTOR_SIZE
          content.copy_to((buffer + offset).to_unsafe, content.size)
        end

        # Entrées de répertoire (LFN + 8.3).
        short_name = unique_short_name(pending.name, used_names)
        used_names << short_name

        # LFN uniquement si le nom ne rentre pas tel quel en 8.3.
        if needs_lfn?(pending.name, short_name)
          checksum = lfn_checksum(short_name)
          lfn_entries_for(pending.name, checksum).each do |e|
            dir_entries << e
          end
        end

        dir_entries << short_dir_entry(short_name, first_cluster, content.size, pending.name)

        next_free_cluster += file_clusters
      end

      if dir_entries.size > @root_entries
        raise ArgumentError.new("répertoire racine plein (#{dir_entries.size} entrées, max #{@root_entries})")
      end

      # Écriture des deux copies de FAT.
      fat_bytes = encode_fat12(fat, @sectors_per_fat * SECTOR_SIZE)
      fat1_offset = @reserved_sectors * SECTOR_SIZE
      fat2_offset = fat1_offset + @sectors_per_fat * SECTOR_SIZE
      fat_bytes.copy_to((buffer + fat1_offset).to_unsafe, fat_bytes.size)
      fat_bytes.copy_to((buffer + fat2_offset).to_unsafe, fat_bytes.size)

      # Écriture du répertoire racine.
      dir_offset = root_dir_sector * SECTOR_SIZE
      dir_entries.each_with_index do |entry, idx|
        entry.copy_to((buffer + dir_offset + idx * DIR_ENTRY_SIZE).to_unsafe, DIR_ENTRY_SIZE)
      end

      buffer
    end

    # Parse une image FAT12 existante et renvoie un `FatImage` dont `#files`
    # contient la liste des fichiers lus. Permet le test aller-retour.
    def self.read(bytes : Bytes) : FatImage
      raise ArgumentError.new("image vide ou tronquée") if bytes.size < SECTOR_SIZE

      bytes_per_sector = read_u16_le(bytes, 11)
      raise ArgumentError.new("sector size #{bytes_per_sector} non supporté") unless bytes_per_sector == SECTOR_SIZE
      sectors_per_cluster = bytes[13].to_i
      reserved_sectors = read_u16_le(bytes, 14).to_i
      num_fats = bytes[16].to_i
      root_entries = read_u16_le(bytes, 17).to_i
      total_sectors16 = read_u16_le(bytes, 19).to_i
      sectors_per_fat = read_u16_le(bytes, 22).to_i
      total_sectors32 = read_u32_le(bytes, 32).to_i64
      total_sectors = total_sectors16 != 0 ? total_sectors16.to_i64 : total_sectors32

      raise ArgumentError.new("image tronquée") if bytes.size.to_i64 < total_sectors * SECTOR_SIZE

      # Étiquette de volume : on lit celle du BPB (offset 43, 11 octets),
      # mais on privilégie l'entrée dédiée du répertoire racine si présente.
      bpb_label = String.new(bytes[43, 11]).rstrip(' ')

      root_dir_sector = reserved_sectors + num_fats * sectors_per_fat
      root_dir_sectors = (root_entries * DIR_ENTRY_SIZE) // SECTOR_SIZE
      data_start_sector = root_dir_sector + root_dir_sectors
      bytes_per_cluster = sectors_per_cluster * SECTOR_SIZE

      # Décodage de la FAT (copie 1 uniquement).
      fat_offset = reserved_sectors * SECTOR_SIZE
      fat_slice = bytes[fat_offset, sectors_per_fat * SECTOR_SIZE]
      fat = decode_fat12(fat_slice)

      image = FatImage.allocate
      image.init_parsed(
        size_bytes: (total_sectors * SECTOR_SIZE).to_i,
        label: bpb_label,
        sectors_per_cluster: sectors_per_cluster,
        reserved_sectors: reserved_sectors,
        num_fats: num_fats,
        root_entries: root_entries,
        total_sectors: total_sectors.to_i,
        sectors_per_fat: sectors_per_fat,
      )

      files = [] of File
      volume_label : String? = nil

      # Lecture séquentielle du répertoire racine, avec reconstitution des LFN.
      lfn_buf = [] of String
      root_offset = root_dir_sector * SECTOR_SIZE
      root_entries.times do |i|
        entry_off = root_offset + i * DIR_ENTRY_SIZE
        entry = bytes[entry_off, DIR_ENTRY_SIZE]
        first = entry[0]
        break if first == 0x00_u8 # fin du répertoire
        next if first == 0xE5_u8  # entrée effacée

        attr = entry[11]
        if attr == ATTR_LFN
          lfn_buf << decode_lfn_entry(entry)
          next
        end

        if (attr & ATTR_VOLUME_ID) != 0_u8 && (attr & ATTR_DIRECTORY) == 0_u8
          volume_label = String.new(entry[0, 11]).rstrip(' ')
          lfn_buf.clear
          next
        end

        next if (attr & ATTR_DIRECTORY) != 0_u8

        # Fichier ordinaire.
        long_name = if lfn_buf.empty?
                      decode_short_name(entry)
                    else
                      # Les entrées LFN précèdent dans l'ordre inverse : le
                      # plus haut numéro de séquence apparaît en premier.
                      lfn_buf.reverse.join
                    end
        lfn_buf.clear

        first_cluster_low = read_u16_le(entry, 26).to_i
        first_cluster_high = read_u16_le(entry, 20).to_i
        first_cluster = (first_cluster_high << 16) | first_cluster_low
        file_size = read_u32_le(entry, 28).to_i

        content = Bytes.new(file_size, 0_u8)
        bytes_remaining = file_size
        cluster = first_cluster
        written = 0
        while bytes_remaining > 0 && cluster >= 2 && cluster < 0xFF8
          src_off = data_start_sector * SECTOR_SIZE + (cluster - 2) * bytes_per_cluster
          to_copy = {bytes_remaining, bytes_per_cluster}.min
          (bytes + src_off).copy_to((content + written).to_unsafe, to_copy)
          written += to_copy
          bytes_remaining -= to_copy
          cluster = fat[cluster]? || 0x0FFF
        end

        files << File.new(long_name, content)
      end

      if vl = volume_label
        image.set_label(vl)
      end
      image.set_files(files)
      image
    end

    # ----------------------------------------------------------------------
    # Internes
    # ----------------------------------------------------------------------

    protected def init_parsed(size_bytes, label, sectors_per_cluster, reserved_sectors, num_fats, root_entries, total_sectors, sectors_per_fat)
      @size_bytes = size_bytes
      @label = label
      @sectors_per_cluster = sectors_per_cluster
      @reserved_sectors = reserved_sectors
      @num_fats = num_fats
      @root_entries = root_entries
      @total_sectors = total_sectors
      @sectors_per_fat = sectors_per_fat
      @media = 0xF8_u8
      @pending = [] of PendingFile
      @files = [] of File
    end

    protected def set_files(files : Array(File))
      @files = files
    end

    protected def set_label(label : String)
      @label = label
    end

    private def normalize_label(label : String) : String
      normalized = label.strip
      raise ArgumentError.new("étiquette > 11 caractères : #{label.inspect}") if normalized.bytesize > 11
      normalized
    end

    private def pick_sectors_per_cluster : Int32
      # Valeurs candidates 1, 2, 4, 8. On choisit la plus petite qui maintient
      # le nombre de clusters utiles sous 4084 (borne haute FAT12).
      [1, 2, 4, 8].each do |spc|
        # Estimation : on ignore le coût des FAT pour ce calcul grossier
        # (il est marginal pour les tailles qui nous intéressent).
        usable_sectors = @total_sectors - 1 - 7 # reserved + root dir
        clusters = usable_sectors // spc
        return spc if clusters <= 4084
      end
      8
    end

    private def compute_sectors_per_fat : Int32
      # FAT12 : 1.5 octet par entrée. On a N clusters de données + 2 entrées
      # réservées. Méthode itérative : une FAT plus grosse réduit la zone de
      # données, donc le nombre de clusters, donc la taille nécessaire de la
      # FAT. On itère jusqu'à convergence.
      root_dir_sectors = (@root_entries * DIR_ENTRY_SIZE) // SECTOR_SIZE
      sectors_per_fat = 1
      loop do
        data_sectors = @total_sectors - @reserved_sectors - @num_fats * sectors_per_fat - root_dir_sectors
        raise ArgumentError.new("image trop petite après entêtes") if data_sectors <= 0
        clusters = data_sectors // @sectors_per_cluster
        fat_bytes_needed = ((clusters + 2) * 3 + 1) // 2 # ceil((n * 1.5))
        needed = (fat_bytes_needed + SECTOR_SIZE - 1) // SECTOR_SIZE
        if needed <= sectors_per_fat
          return sectors_per_fat
        end
        sectors_per_fat = needed
      end
    end

    private def write_boot_sector(buffer : Bytes) : Nil
      # Saut court + NOP : instructions x86 inoffensives, exigées par la spec.
      buffer[0] = 0xEB_u8
      buffer[1] = 0x3C_u8
      buffer[2] = 0x90_u8

      # OEM name (8 octets ASCII).
      oem = "SILEX1.0"
      oem.bytesize.times { |i| buffer[3 + i] = oem.byte_at(i) }

      write_u16_le(buffer, 11, SECTOR_SIZE)
      buffer[13] = @sectors_per_cluster.to_u8
      write_u16_le(buffer, 14, @reserved_sectors)
      buffer[16] = @num_fats.to_u8
      write_u16_le(buffer, 17, @root_entries)
      if @total_sectors < 0x10000
        write_u16_le(buffer, 19, @total_sectors)
        write_u32_le(buffer, 32, 0_u32)
      else
        write_u16_le(buffer, 19, 0)
        write_u32_le(buffer, 32, @total_sectors.to_u32)
      end
      buffer[21] = @media
      write_u16_le(buffer, 22, @sectors_per_fat)
      write_u16_le(buffer, 24, 32)    # secteurs par piste (valeur de courtoisie)
      write_u16_le(buffer, 26, 64)    # têtes (idem)
      write_u32_le(buffer, 28, 0_u32) # secteurs cachés

      # Extended BPB (FAT12/16).
      buffer[36] = 0x80_u8                     # drive number (disque dur)
      buffer[37] = 0x00_u8                     # réservé
      buffer[38] = 0x29_u8                     # signature BPB étendu (0x29 → serial + label + fstype présents)
      write_u32_le(buffer, 39, 0x12345678_u32) # serial volume
      11.times do |i|
        buffer[43 + i] = i < @label.bytesize ? @label.byte_at(i) : 0x20_u8
      end
      fstype = "FAT12   "
      fstype.bytesize.times { |i| buffer[54 + i] = fstype.byte_at(i) }

      # Signature boot (0x55AA en fin du secteur 0).
      buffer[510] = 0x55_u8
      buffer[511] = 0xAA_u8
    end

    private def encode_fat12(fat : Array(UInt16), byte_size : Int32) : Bytes
      buf = Bytes.new(byte_size, 0_u8)
      i = 0
      while i < fat.size
        pair_index = i // 2
        offset = pair_index * 3
        break if offset + 2 >= byte_size
        low = fat[i] & 0x0FFF_u16
        high = (i + 1 < fat.size ? fat[i + 1] : 0_u16) & 0x0FFF_u16
        # Deux entrées de 12 bits empaquetées sur 3 octets.
        buf[offset] = (low & 0xFF).to_u8
        buf[offset + 1] = (((low >> 8) & 0x0F) | ((high & 0x0F) << 4)).to_u8
        buf[offset + 2] = ((high >> 4) & 0xFF).to_u8
        i += 2
      end
      buf
    end

    private def self.decode_fat12(bytes : Bytes) : Array(UInt16)
      entries = (bytes.size * 2) // 3
      fat = Array(UInt16).new(entries, 0_u16)
      i = 0
      while i < entries
        pair_index = i // 2
        offset = pair_index * 3
        break if offset + 2 >= bytes.size
        b0 = bytes[offset].to_u16
        b1 = bytes[offset + 1].to_u16
        b2 = bytes[offset + 2].to_u16
        low = b0 | ((b1 & 0x0F_u16) << 8)
        high = (b1 >> 4) | (b2 << 4)
        fat[i] = low & 0x0FFF_u16
        fat[i + 1] = high & 0x0FFF_u16 if i + 1 < entries
        i += 2
      end
      fat
    end

    private def volume_label_entry : Bytes
      entry = Bytes.new(DIR_ENTRY_SIZE, 0_u8)
      11.times do |i|
        entry[i] = i < @label.bytesize ? @label.byte_at(i) : 0x20_u8
      end
      entry[11] = ATTR_VOLUME_ID
      entry
    end

    # Génère un nom 8.3 unique pour l'entrée courte, en recourant au suffixe
    # `~N` dès que la transformation perd de l'information.
    private def unique_short_name(name : String, used : Set(String)) : String
      base_upper, ext_upper, is_lossy = to_short_parts(name)
      base = base_upper
      ext = ext_upper

      # Si le nom rentre en 8.3 sans perte, on le prend tel quel.
      if !is_lossy && base.size <= 8
        candidate = format_short(base, ext)
        return candidate unless used.includes?(candidate)
      end

      # Sinon, on ajoute un suffixe ~N avec N croissant.
      prefix = base[0, {base.size, 6}.min]
      (1..99).each do |n|
        suffix = "~#{n}"
        candidate_base = "#{prefix[0, 8 - suffix.size]}#{suffix}"
        candidate = format_short(candidate_base, ext)
        return candidate unless used.includes?(candidate)
      end
      raise ArgumentError.new("impossible de générer un nom court unique pour #{name.inspect}")
    end

    # Transforme un nom long en (base, extension) en majuscules, en rapportant
    # si la transformation est "lossy" (force l'usage du LFN).
    private def to_short_parts(name : String) : {String, String, Bool}
      # Séparation base / extension sur le dernier point.
      dot_index = name.rindex('.')
      base_raw = dot_index ? name[0, dot_index] : name
      ext_raw = dot_index ? name[(dot_index + 1)..] : ""

      is_lossy = false
      is_lossy = true if dot_index == 0 || name.count('.') > 1
      is_lossy = true if base_raw.size > 8 || ext_raw.size > 3
      is_lossy = true if name != name.upcase
      is_lossy = true if name.each_char.any? { |c| !allowed_short_char?(c) }

      base = sanitize_short(base_raw)[0, 8]
      ext = sanitize_short(ext_raw)[0, 3]
      {base, ext, is_lossy}
    end

    private def sanitize_short(input : String) : String
      String.build do |io|
        input.each_char do |c|
          up = c.upcase
          if allowed_short_char?(up)
            io << up
          else
            io << '_'
          end
        end
      end
    end

    private def allowed_short_char?(c : Char) : Bool
      return true if c.ascii_uppercase? || c.ascii_number?
      # Caractères autorisés dans un nom 8.3 "strict" (pas de tiret,
      # pas d'espace ; on les remplacera par '_').
      "!#$%&'()-@^_`{}~".includes?(c)
    end

    private def format_short(base : String, ext : String) : String
      padded_base = base.ljust(8, ' ')
      padded_ext = ext.ljust(3, ' ')
      "#{padded_base}#{padded_ext}"
    end

    private def needs_lfn?(long_name : String, short_11 : String) : Bool
      base = short_11[0, 8].rstrip(' ')
      ext = short_11[8, 3].rstrip(' ')
      reconstructed = ext.empty? ? base : "#{base}.#{ext}"
      reconstructed != long_name
    end

    # Somme de contrôle du nom 8.3 pour lier une entrée LFN à son entrée courte.
    # Référence : Microsoft FAT spec.
    private def lfn_checksum(short_11 : String) : UInt8
      sum = 0_u8
      11.times do |i|
        c = short_11.byte_at(i)
        sum = (((sum & 1_u8) << 7_u8) &+ (sum >> 1_u8) &+ c).to_u8
      end
      sum
    end

    private def lfn_entries_for(long_name : String, checksum : UInt8) : Array(Bytes)
      # UTF-16LE, par paquets de 13 caractères par entrée LFN.
      chars = long_name.chars
      # Caractère NUL terminateur + padding 0xFFFF jusqu'à multiple de 13.
      padded = chars.dup
      padded << '\0'
      while padded.size % 13 != 0
        padded << '\uFFFF'
      end

      num_entries = padded.size // 13
      entries = Array(Bytes).new(num_entries)
      num_entries.times do |i|
        seq = i + 1
        is_last = (i == num_entries - 1)
        entry = Bytes.new(DIR_ENTRY_SIZE, 0_u8)
        entry[0] = (is_last ? (seq | 0x40) : seq).to_u8
        entry[11] = ATTR_LFN
        entry[12] = 0_u8 # type
        entry[13] = checksum
        entry[26] = 0_u8 # first cluster low (toujours 0 pour LFN)
        entry[27] = 0_u8

        slice = padded[i * 13, 13]
        # Dispatch des 13 caractères dans les champs LFN (5 + 6 + 2).
        layout_offsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        slice.each_with_index do |ch, idx|
          code = ch.ord.to_u16
          off = layout_offsets[idx]
          entry[off] = (code & 0xFF).to_u8
          entry[off + 1] = ((code >> 8) & 0xFF).to_u8
        end
        # Les LFN sont stockées dans l'ordre séquence descendante, on les
        # push inversées pour que la plus haute apparaisse en premier.
        entries.unshift(entry)
      end
      entries
    end

    private def short_dir_entry(short_11 : String, first_cluster : Int32, size : Int32, long_name : String) : Bytes
      entry = Bytes.new(DIR_ENTRY_SIZE, 0_u8)
      11.times do |i|
        entry[i] = short_11.byte_at(i)
      end
      entry[11] = ATTR_ARCHIVE
      entry[12] = 0_u8 # NT reserved
      entry[13] = 0_u8 # dixièmes de seconde création
      # Horodatage fixe : 2026-04-18 12:00:00 local.
      # Format FAT :
      #   time = (h << 11) | (m << 5) | (s / 2)
      #   date = ((year - 1980) << 9) | (month << 5) | day
      time_val = (12_u16 << 11_u16) | (0_u16 << 5_u16) | 0_u16
      date_val = ((2026_u16 - 1980_u16) << 9_u16) | (4_u16 << 5_u16) | 18_u16
      write_u16_le(entry, 14, time_val)
      write_u16_le(entry, 16, date_val)
      write_u16_le(entry, 18, date_val) # last access
      write_u16_le(entry, 20, 0_u16)    # high cluster (FAT12/16 = 0)
      write_u16_le(entry, 22, time_val)
      write_u16_le(entry, 24, date_val)
      write_u16_le(entry, 26, first_cluster.to_u16)
      write_u32_le(entry, 28, size.to_u32)
      entry
    end

    private def self.decode_lfn_entry(entry : Bytes) : String
      layout_offsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
      String.build do |io|
        layout_offsets.each do |off|
          code = (entry[off].to_u16) | (entry[off + 1].to_u16 << 8)
          break if code == 0x0000
          next if code == 0xFFFF
          io << code.chr
        end
      end
    end

    private def self.decode_short_name(entry : Bytes) : String
      base = String.new(entry[0, 8]).rstrip(' ')
      ext = String.new(entry[8, 3]).rstrip(' ')
      ext.empty? ? base : "#{base}.#{ext}"
    end

    # --- helpers binaires ---

    private def write_u16_le(buf : Bytes, offset : Int, value)
      v = value.to_u16
      buf[offset] = (v & 0xFF).to_u8
      buf[offset + 1] = ((v >> 8) & 0xFF).to_u8
    end

    private def write_u32_le(buf : Bytes, offset : Int, value)
      v = value.to_u32
      buf[offset] = (v & 0xFF).to_u8
      buf[offset + 1] = ((v >> 8) & 0xFF).to_u8
      buf[offset + 2] = ((v >> 16) & 0xFF).to_u8
      buf[offset + 3] = ((v >> 24) & 0xFF).to_u8
    end

    private def self.read_u16_le(buf : Bytes, offset : Int) : UInt16
      buf[offset].to_u16 | (buf[offset + 1].to_u16 << 8)
    end

    private def self.read_u32_le(buf : Bytes, offset : Int) : UInt32
      buf[offset].to_u32 |
        (buf[offset + 1].to_u32 << 8) |
        (buf[offset + 2].to_u32 << 16) |
        (buf[offset + 3].to_u32 << 24)
    end
  end
end
