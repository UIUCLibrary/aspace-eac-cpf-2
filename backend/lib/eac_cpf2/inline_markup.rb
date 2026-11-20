# frozen_string_literal: true

require 'nokogiri'

module EacCpf2
  # Converts the text of an ArchivesSpace note into EAC-CPF 2.0 paragraphs.
  #
  # Note text in ArchivesSpace is a string that may contain EAD inline markup
  # (<emph render="italic">, <title>, <extref xlink:href>, <lb/>, <p>). EAC-CPF
  # 2.0 paragraphs allow only text, <span> and <reference>, so:
  #
  # * <emph>, <title> and other formatting elements become
  #   <span localType="{element}" style="{CSS}">, translating EAD's @render
  #   into the CSS the EAC-CPF tag library recommends for @style (quotation
  #   renders become quotation marks);
  # * elements with an href become <reference href="...">, except in-note
  #   fragment links (href="#ftn1"), which keep only their text;
  # * HTML formatting (<i>, <em>, <b>, <strong>, <u>, <sup>, <sub>), which
  #   ArchivesSpace also accepts, becomes a <span> with the equivalent CSS;
  # * <lb/> and <br/> become line breaks;
  # * <p> elements, blank lines and Archon's newline-tab separate paragraphs,
  #   and each <li> of a
  #   list becomes a bulleted paragraph (EAC-CPF paragraphs cannot hold lists);
  # * anything else contributes its text.
  #
  # Markup that is not well formed is kept as literal text rather than lost.
  module InlineMarkup
    Text = Struct.new(:text)
    Span = Struct.new(:local_type, :style, :children)
    Reference = Struct.new(:href, :children)

    LINK_ELEMENTS = %w[extref ref archref extptr ptr dao].freeze
    FORMAT_ELEMENTS = %w[emph title span name persname corpname famname geogname subject genreform occupation function date num].freeze
    PARAGRAPH_BREAK = /\n[ \t]*\n/

    RENDER_CSS = {
      'italic' => 'font-style: italic',
      'bold' => 'font-weight: bold',
      'bolditalic' => 'font-weight: bold; font-style: italic',
      'underline' => 'text-decoration: underline',
      'boldunderline' => 'font-weight: bold; text-decoration: underline',
      'smcaps' => 'font-variant: small-caps',
      'boldsmcaps' => 'font-weight: bold; font-variant: small-caps',
      'super' => 'vertical-align: super',
      'sub' => 'vertical-align: sub'
    }.freeze

    HTML_CSS = {
      'i' => 'font-style: italic', 'em' => 'font-style: italic', 'cite' => 'font-style: italic',
      'b' => 'font-weight: bold', 'strong' => 'font-weight: bold', 'u' => 'text-decoration: underline',
      'sup' => 'vertical-align: super', 'sub' => 'vertical-align: sub'
    }.freeze

    LIST_ELEMENTS = %w[ul ol list].freeze
    BULLET = "\u2022 "

    RENDER_QUOTES = {
      'quoted' => %w[“ ”], 'doublequote' => %w[“ ”], 'singlequote' => %w[‘ ’],
      'bolddoublequote' => %w[“ ”], 'boldsinglequote' => %w[‘ ’]
    }.freeze

    module_function

    # @param content [String, Array<String>]
    # @return [Array<Array<Text, Span, Reference>>] one entry per paragraph
    def paragraphs(content)
      Array(content).flat_map { |text| paragraphs_of(text.to_s) }
    end

    # A newline followed by a tab is how Archon separated paragraphs.
    # ArchivesSpace's EAD exporter (handle_linebreaks) treats it as a blank
    # line, and so does this, so creator notes split where collection notes do.
    ARCHON_PARAGRAPH_BREAK = "\n\t"

    def paragraphs_of(text)
      text = text.gsub(ARCHON_PARAGRAPH_BREAK, "\n\n")
      return [] if text.strip.empty?
      return plain_paragraphs(text) unless text.include?('<')

      root = parse(text) || parse(repair_entities(text))
      return plain_paragraphs(strip_tags(text)) unless root

      split_paragraphs(root).map { |nodes| trim(nodes) }.reject(&:empty?)
    end

    def parse(text)
      doc = Nokogiri::XML("<root xmlns:xlink=\"http://www.w3.org/1999/xlink\">#{text}</root>") { |config| config.nonet }
      return nil unless doc.errors.empty?

      doc.root
    end

    XML_ENTITIES = %w[amp lt gt quot apos].freeze

    # Escapes bare ampersands and replaces HTML named entities, which are not
    # defined in XML, with the characters they stand for.
    def repair_entities(text)
      text.gsub(/&(#?[A-Za-z0-9]+;)?/) do |match|
        entity = Regexp.last_match(1)
        next '&amp;' unless entity
        next match if entity.start_with?('#') || XML_ENTITIES.include?(entity.chomp(';'))

        decoded = Nokogiri::HTML.fragment(match).text
        decoded == match ? "&amp;#{entity}" : decoded.encode(xml: :text)
      end
    end

    def strip_tags(text)
      Nokogiri::HTML.fragment(text.gsub(PARAGRAPH_BREAK, "\u2029")).text.gsub("\u2029", "\n\n")
    end

    def plain_paragraphs(text)
      text.split(PARAGRAPH_BREAK).map(&:strip).reject(&:empty?).map { |para| [Text.new(para)] }
    end

    # Walks the top level, starting a new paragraph at each <p> and blank line.
    def split_paragraphs(root)
      paragraphs = [[]]
      root.children.each do |node|
        if node.element? && node.name == 'p'
          paragraphs << convert_children(node)
          paragraphs << []
        elsif node.element? && LIST_ELEMENTS.include?(node.name)
          node.element_children.select { |child| %w[li item].include?(child.name) }.each do |item|
            paragraphs << [Text.new(BULLET), *convert_children(item)]
          end
          paragraphs << []
        elsif node.text?
          parts = node.text.split(PARAGRAPH_BREAK, -1)
          parts.each_with_index do |part, index|
            paragraphs << [] if index.positive?
            paragraphs.last << Text.new(part) unless part.empty?
          end
        else
          paragraphs.last.concat(convert(node))
        end
      end
      paragraphs
    end

    def convert_children(node)
      node.children.flat_map { |child| convert(child) }
    end

    def convert(node)
      return [Text.new(node.text)] if node.text? || node.cdata?
      return [] unless node.element?
      return [Text.new("\n")] if %w[lb br].include?(node.name)

      href = node['href'] || node.attribute_with_ns('href', 'http://www.w3.org/1999/xlink')&.value
      children = convert_children(node)
      # A bare fragment (#ftn1) points at an anchor in the original note,
      # which does not survive, so only the text is kept.
      if href && !href.strip.empty? && !href.strip.start_with?('#')
        children = [Text.new(href)] if children.empty?
        return [Reference.new(href.strip, children)]
      end
      render = node['render'].to_s.strip.downcase
      if (quotes = RENDER_QUOTES[render])
        children = [Text.new(quotes[0]), *children, Text.new(quotes[1])]
        render = render.start_with?('bold') ? 'bold' : ''
        return children if render.empty? && node.name == 'emph'
      end
      return children if children.empty?
      return [Span.new(node.name, HTML_CSS[node.name], children)] if HTML_CSS.key?(node.name)
      return children unless FORMAT_ELEMENTS.include?(node.name)

      [Span.new(node.name, RENDER_CSS[render], children)]
    end

    def trim(nodes)
      nodes = nodes.dup
      nodes.shift while nodes.first.is_a?(Text) && nodes.first.text.strip.empty?
      nodes.pop while nodes.last.is_a?(Text) && nodes.last.text.strip.empty?
      nodes[0] = Text.new(nodes[0].text.lstrip) if nodes.first.is_a?(Text)
      nodes[-1] = Text.new(nodes[-1].text.rstrip) if nodes.last.is_a?(Text)
      nodes
    end

    # Writes converted nodes into a Nokogiri builder positioned inside <p>.
    def write(xml, nodes)
      nodes.each do |node|
        case node
        when Text
          xml.text(node.text)
        when Span
          attrs = { 'localType' => node.local_type }
          attrs['style'] = node.style if node.style && !node.style.empty?
          xml.span(attrs) { write_flat(xml, node.children) }
        when Reference
          xml.reference('href' => node.href) { write_spans_only(xml, node.children) }
        end
      end
    end

    # <span> holds text only, so nested markup inside it is flattened.
    def write_flat(xml, nodes)
      xml.text(flatten(nodes))
    end

    # <reference> holds text and <span>; a nested link is reduced to its text.
    def write_spans_only(xml, nodes)
      nodes.each do |node|
        case node
        when Text then xml.text(node.text)
        when Span
          attrs = { 'localType' => node.local_type }
          attrs['style'] = node.style if node.style && !node.style.empty?
          xml.span(attrs) { write_flat(xml, node.children) }
        when Reference then xml.text(flatten(node.children))
        end
      end
    end

    def flatten(nodes)
      nodes.map { |node| node.is_a?(Text) ? node.text : flatten(node.children) }.join
    end
  end
end
