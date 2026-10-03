require "xml"

module E2E
  # Turns an HTML document into a canonical text form: one line per element
  # and text node, attributes sorted and decoded, whitespace collapsed the
  # way a browser renders it. Two pages with the same canonical form look
  # and behave the same (the JS and CSS are byte-identical).
  module DOM
    # Elements that never render surrounding whitespace by themselves.
    INLINE = %w(a abbr b bdi bdo br button cite code data del dfn em i img input ins kbd label mark
      output q s samp select small span strong sub sup svg textarea time u use var wbr)

    # Attributes whose value is irrelevant (presence only).
    BOOLEAN = %w(checked selected disabled required hidden open defer async formnovalidate readonly
      multiple autofocus novalidate)

    def self.canonical(html : String) : String
      doc = XML.parse_html(html, XML::HTMLParserOptions.default | XML::HTMLParserOptions::NONET)
      String.build do |io|
        if root = doc.root
          walk(root, io, 0, false)
        end
      end
    end

    private def self.walk(node : XML::Node, io : IO, depth : Int32, pre : Bool) : Nil
      case node.type
      when .element_node?
        name = node.name.downcase
        io << "  " * depth << "<" << name
        attrs = node.attributes.map do |a|
          k = a.name.downcase
          v = BOOLEAN.includes?(k) ? "" : a.content
          v = v.split.join(" ") if k == "class"
          {k, v}
        end
        attrs.sort!.each { |k, v| io << " " << k << "=" << v.inspect }
        io << ">\n"
        inner_pre = pre || name.in?("pre", "textarea")
        node.children.each { |c| walk(c, io, depth + 1, inner_pre) }
      when .text_node?, .cdata_section_node?
        text = node.content
        unless pre
          text = text.gsub(/[ \t\n\r\f]+/, " ")
          text = text.lstrip if block_boundary?(node.previous_sibling, node.parent)
          text = text.rstrip if block_boundary?(node.next_sibling, node.parent)
        end
        io << "  " * depth << text.inspect << "\n" unless text.empty?
      else
        # comments, processing instructions: invisible
      end
    end

    # Whitespace next to a block element (or at the edge of a block parent)
    # is not rendered.
    private def self.block_boundary?(sibling : XML::Node?, parent : XML::Node?) : Bool
      if sibling.nil?
        parent.nil? || !INLINE.includes?(parent.name.downcase)
      elsif sibling.element?
        !INLINE.includes?(sibling.name.downcase)
      else
        false
      end
    end

    # `<script>` elements without src and on* attributes: what an escaping
    # bug would produce. The app's CSP forbids both anyway.
    def self.injected_scripts(doc : XML::Node) : Array(String)
      found = [] of String
      doc.xpath_nodes("//script[not(@src)]").each { |n| found << n.to_s }
      doc.xpath_nodes("//*[@*[starts-with(name(), 'on')]]").each { |n| found << n.to_s[0, 200] }
      found
    end
  end
end
