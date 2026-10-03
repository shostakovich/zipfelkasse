require "socket"

module Zipfelkasse
  class Config
    # An IP network; IPv4 is stored IPv4-mapped (::ffff:a.b.c.d), a single address has length 128.
    struct Prefix
      V4_MAPPED = 0xffff_u128 << 32

      getter bits : UInt128
      getter length : Int32

      def initialize(bits : UInt128, @length = 128)
        @bits = bits & mask
      end

      def self.parse_list(text : String) : Array(Prefix)
        text.split(/[,\s]+/, remove_empty: true).map { |item| parse(item) }
      end

      def self.parse(text : String) : Prefix
        address, slash, length = text.partition('/')
        prefix = parse_address?(address) || raise ArgumentError.new("#{address.inspect} is not an IP address#{" or network" if slash.empty?}")
        return prefix if slash.empty?
        max = address.includes?(':') ? 128 : 32
        n = length.to_i? if length.matches?(/\A\d+\z/)
        raise ArgumentError.new("#{length.inspect} is not a valid prefix length for #{address}") if n.nil? || n > max
        new(prefix.bits, n + 128 - max)
      end

      def self.parse_address?(text : String) : Prefix?
        bits = if text.includes?(':')
                 Socket::IPAddress.parse_v6_fields?(text).try(&.reduce(0_u128) { |sum, field| sum << 16 | field })
               else
                 Socket::IPAddress.parse_v4_fields?(text).try { |fields| V4_MAPPED | fields.reduce(0_u128) { |sum, byte| sum << 8 | byte } }
               end
        new(bits) if bits
      end

      def contains?(other : Prefix) : Bool
        other.bits & mask == @bits
      end

      def v4? : Bool
        @length >= 96 && @bits >> 32 == 0xffff
      end

      def to_s(io : IO) : Nil
        if v4?
          (0..3).join(io, '.') { |i, io| io << (@bits >> (24 - 8 * i) & 0xff) }
          io << '/' << @length - 96 if @length < 128
        else
          fields = StaticArray(UInt16, 8).new { |i| (@bits >> (112 - 16 * i)).to_u16! }
          io << Socket::IPAddress.v6(fields, 0_u16).address
          io << '/' << @length if @length < 128
        end
      end

      private def mask : UInt128
        UInt128::MAX << (128 - @length)
      end
    end
  end
end
