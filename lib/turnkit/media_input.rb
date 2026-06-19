# frozen_string_literal: true

require "pathname"
require "stringio"
require "uri"

module TurnKit
  class MediaInput
    SUPPORTED_MIME_TYPES = %w[image/png image/jpeg image/webp image/gif application/pdf].freeze
    EXTENSION_MIME_TYPES = {
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".webp" => "image/webp",
      ".gif" => "image/gif",
      ".pdf" => "application/pdf",
      ".mp3" => "audio/mpeg",
      ".wav" => "audio/wav",
      ".m4a" => "audio/mp4",
      ".mp4" => "video/mp4",
      ".mov" => "video/quicktime",
      ".webm" => "video/webm"
    }.freeze

    attr_reader :source, :mime_type, :filename, :metadata, :source_type

    def self.wrap(value, **options)
      value.is_a?(self) && options.empty? ? value : new(value, **options)
    end

    def self.bytes(data, mime_type:, filename: nil, metadata: {})
      new(data, source_type: :bytes, mime_type: mime_type, filename: filename, metadata: metadata)
    end

    def initialize(source, mime_type: nil, filename: nil, metadata: {}, source_type: nil)
      @source = source
      @source_type = (source_type || infer_source_type).to_s
      @filename = filename || infer_filename
      @mime_type = mime_type || infer_mime_type
      @metadata = metadata || {}

      validate!
    end

    def kind
      return "image" if mime_type&.start_with?("image/")
      return "audio" if mime_type&.start_with?("audio/")
      return "video" if mime_type&.start_with?("video/")
      return "pdf" if mime_type == "application/pdf"

      nil
    end

    def byte_size
      case source_type
      when "path"
        File.size(source.to_s) if File.file?(source.to_s)
      when "bytes"
        source.bytesize
      when "io"
        source.size if source.respond_to?(:size)
      when "active_storage"
        active_storage_byte_size
      end
    end

    def url
      source.to_s if source_type == "url"
    end

    def path
      source.to_s if source_type == "path"
    end

    def attachment_source
      case source_type
      when "bytes"
        StringIO.new(source)
      else
        source
      end
    end

    def to_h
      {
        "kind" => kind,
        "mime_type" => mime_type,
        "filename" => filename,
        "byte_size" => byte_size,
        "url" => url,
        "path" => path,
        "metadata" => metadata
      }.compact
    end

    private
      def infer_source_type
        return :url if source.to_s.match?(%r{\Ahttps?://})
        return :active_storage if active_storage?
        return :path if source.is_a?(Pathname) || (source.is_a?(String) && File.exist?(source))
        return :io if source.respond_to?(:read)
        return :bytes if source.is_a?(String)

        raise ArgumentError, "unsupported media input: #{source.class}"
      end

      def infer_filename
        case source_type
        when "url"
          basename = File.basename(URI(source.to_s).path).to_s
          basename.empty? ? nil : basename
        when "path"
          File.basename(source.to_s)
        when "io"
          source.respond_to?(:path) ? File.basename(source.path.to_s) : nil
        when "active_storage"
          active_storage_filename
        end
      end

      def infer_mime_type
        active_storage_content_type || mime_from_filename || mime_from_marcel
      end

      def mime_from_filename
        EXTENSION_MIME_TYPES[File.extname(filename.to_s).downcase]
      end

      def mime_from_marcel
        require "marcel"

        Marcel::MimeType.for(marcel_io, name: filename)
      rescue LoadError
        nil
      ensure
        rewind_source
      end

      def marcel_io
        case source_type
        when "path"
          Pathname.new(source.to_s)
        when "bytes"
          StringIO.new(source)
        when "io"
          source
        else
          nil
        end
      end

      def validate!
        return if mime_type.nil?
        return if SUPPORTED_MIME_TYPES.include?(mime_type)
        return if mime_type.start_with?("audio/", "video/")

        raise ArgumentError, "unsupported media type: #{mime_type}"
      end

      def active_storage?
        return false unless defined?(ActiveStorage)

        (defined?(ActiveStorage::Blob) && source.is_a?(ActiveStorage::Blob)) ||
          (defined?(ActiveStorage::Attached::One) && source.is_a?(ActiveStorage::Attached::One)) ||
          (defined?(ActiveStorage::Attached::Many) && source.is_a?(ActiveStorage::Attached::Many))
      end

      def active_storage_filename
        if defined?(ActiveStorage::Blob) && source.is_a?(ActiveStorage::Blob)
          source.filename.to_s
        elsif source.respond_to?(:filename)
          source.filename.to_s
        elsif source.respond_to?(:blob)
          source.blob&.filename&.to_s
        elsif source.respond_to?(:blobs)
          source.blobs.first&.filename&.to_s
        end
      end

      def active_storage_content_type
        if defined?(ActiveStorage::Blob) && source.is_a?(ActiveStorage::Blob)
          source.content_type
        elsif source.respond_to?(:content_type)
          source.content_type
        elsif source.respond_to?(:blob)
          source.blob&.content_type
        elsif source.respond_to?(:blobs)
          source.blobs.first&.content_type
        end
      end

      def active_storage_byte_size
        if defined?(ActiveStorage::Blob) && source.is_a?(ActiveStorage::Blob)
          source.byte_size
        elsif source.respond_to?(:byte_size)
          source.byte_size
        elsif source.respond_to?(:blob)
          source.blob&.byte_size
        elsif source.respond_to?(:blobs)
          source.blobs.first&.byte_size
        end
      end

      def rewind_source
        source.rewind if source_type == "io" && source.respond_to?(:rewind)
      end
  end
end
