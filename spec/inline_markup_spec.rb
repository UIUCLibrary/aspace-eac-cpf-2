# frozen_string_literal: true

RSpec.describe EacCpf2::InlineMarkup do
  def render(content)
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.root { described_class.paragraphs(content).each { |para| xml.p { described_class.write(xml, para) } } }
    end
    builder.doc.root.children.map { |node| node.to_xml(encoding: 'UTF-8') }
  end

  it 'turns EAD formatting into spans that keep the element and render style' do
    expect(render('Read <title render="italic">Moby-Dick</title>.')).to eq [
      '<p>Read <span localType="title" style="font-style: italic">Moby-Dick</span>.</p>'
    ]
  end

  it 'renders quotation styles as quotation marks' do
    expect(render('Called <emph render="doublequote">Squire</emph>')).to eq ["<p>Called \u201CSquire\u201D</p>"]
  end

  it 'turns HTML formatting into spans with the equivalent CSS and drops bare anchors' do
    expect(render('Note<sup>1</sup> <a name="fn1">here</a> <b>bold</b>')).to eq [
      '<p>Note<span localType="sup" style="vertical-align: super">1</span> here ' \
      '<span localType="b" style="font-weight: bold">bold</span></p>'
    ]
  end

  it 'makes each list item a bulleted paragraph' do
    expect(render('Units:<ul><li>Archives</li><li>Library</li></ul>After')).to eq [
      '<p>Units:</p>', "<p>\u2022 Archives</p>", "<p>\u2022 Library</p>", '<p>After</p>'
    ]
  end

  it 'turns links into references' do
    expect(render('See <extref xlink:href="https://example.edu">the guide</extref>.')).to eq [
      '<p>See <reference href="https://example.edu">the guide</reference>.</p>'
    ]
  end

  it 'keeps only the text of links to anchors inside the note' do
    expect(render('Founded 1941.<a href="#ftn1"><sup>1</sup></a>')).to eq [
      '<p>Founded 1941.<span localType="sup" style="vertical-align: super">1</span></p>'
    ]
  end

  it 'starts a new paragraph at blank lines and at <p> elements' do
    expect(render("One.\n\nTwo.<p>Three.</p>")).to eq ['<p>One.</p>', '<p>Two.</p>', '<p>Three.</p>']
  end

  # As ArchivesSpace's EAD exporter does (handle_linebreaks, "4archon")
  it 'treats a newline followed by a tab, which Archon used between paragraphs, as a paragraph break' do
    expect(render("Theory.<emph render='super'>7</emph>\n\t1. Board report.\n\t2. Catalog.")).to eq [
      '<p>Theory.<span localType="emph" style="vertical-align: super">7</span></p>', '<p>1. Board report.</p>', '<p>2. Catalog.</p>'
    ]
  end

  it 'parses markup alongside bare ampersands and HTML entities' do
    expect(render('A &amp; B & C&nbsp;<emph render="bold">D</emph>')).to eq [
      "<p>A &amp; B &amp; C\u00A0<span localType=\"emph\" style=\"font-weight: bold\">D</span></p>"
    ]
  end

  it 'keeps the text of markup that is not well formed, without the tags' do
    expect(render('Broken <emph render="italic">markup')).to eq ['<p>Broken markup</p>']
  end
end
