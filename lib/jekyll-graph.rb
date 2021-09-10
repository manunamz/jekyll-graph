# frozen_string_literal: true
require "jekyll"

require_relative "jekyll-graph/context"
require_relative "jekyll-graph/version"

# setup config
require_relative "jekyll-graph/config"
Jekyll::Hooks.register :site, :after_init do |site|
  # global '$graph_conf' to ensure that all local jekyll plugins
  # are reading from the same configuration
  # (global var is not ideal, but is DRY)
  $graph_conf = Jekyll::Graph::PluginConfig.new(site.config)
end

require_relative "jekyll-graph/tags"
Liquid::Template.register_tag "force_graph", Jekyll::Graph::ForceGraphTag
Liquid::Template.register_tag "graph_scripts", Jekyll::Graph::GraphScriptTag

module Jekyll
  module Graph

    class PageWithoutAFile < Page
      # rubocop:disable Naming/MemoizedInstanceVariableName
      def read_yaml(*)
        @data ||= {}
      end
      # rubocop:enable Naming/MemoizedInstanceVariableName
    end

    class Generator < Jekyll::Generator
      priority :lowest

      # Use Jekyll's native relative_url filter
      include Jekyll::Filters::URLFilters

      CONVERTER_CLASS = Jekyll::Converters::Markdown

      def generate(site)
        return if $graph_conf.disabled?
        if !$graph_conf.disabled_type_net_web? && site.link_index.nil?
          Jekyll.logger.error("To generate the net-web graph, please add and enable the 'jekyll-wikilinks' plugin")
          return
        end
        if !$graph_conf.disabled_type_tree? && site.tree.nil?
          Jekyll.logger.error("To generate the tree graph, please add and enable the 'jekyll-namespaces' plugin")
          return
        end

        # setup site
        @site = site
        @context ||= Context.new(site)

        if !File.directory?(File.join(@site.source, $graph_conf.path_assets))
          Jekyll.logger.error "Assets location does not exist, please create required directories for path: ", $graph_conf.path_assets
        end

        # setup markdown docs
        docs = []
        docs += @site.pages if !$graph_conf.excluded?(:pages)
        docs += @site.docs_to_write.filter { |d| !$graph_conf.excluded?(d.type) }
        @md_docs = docs.filter { |doc| markdown_extension?(doc.extname) }
        if @md_docs.empty?
          Jekyll.logger.debug("No documents to process.")
        end

        # write graph
        if !$graph_conf.disabled_type_net_web?
          # generate json data
          json_net_web_nodes, json_net_web_links = self.generate_json_net_web()
          self.set_neighbors(json_net_web_nodes, json_net_web_links)
          net_web_graph_content = JSON.dump(
            nodes: json_net_web_nodes,
            links: json_net_web_links,
          )
          # create json file
          json_net_web_graph_file = self.new_page($graph_conf.path_assets, "graph-net-web.json", net_web_graph_content)
          self.register_static_file(json_net_web_graph_file)
        end
        if !$graph_conf.disabled_type_tree?
          # generate json data
          json_tree_nodes, json_tree_links = self.generate_json_tree(@site.tree.root)
          self.set_relatives(json_tree_nodes, json_tree_links)
          tree_graph_content = JSON.dump(
            nodes: json_tree_nodes,
            links: json_tree_links,
          )
          # create json file
          json_tree_graph_file = self.new_page($graph_conf.path_assets, "graph-tree.json", tree_graph_content)
          self.register_static_file(json_tree_graph_file)
        end
        # add graph drawing scripts
        script_filename = "jekyll-graph.js"
        graph_script_content = File.read(source_path(script_filename))
        static_file = self.new_page($graph_conf.path_scripts, script_filename, graph_script_content)
        self.register_static_file(static_file)
      end

      # helpers

      # from: https://github.com/jekyll/jekyll-sitemap/blob/master/lib/jekyll/jekyll-sitemap.rb#L39
      def source_path(file)
        File.expand_path "jekyll-graph/#{file}", __dir__
      end

      # Checks if a file already exists in the site source
      def file_exists?(file_path)
        @site.static_files.any? { |p| p.url == "/#{file_path}" }
      end

      def markdown_extension?(extension)
        markdown_converter.matches(extension)
      end

      def markdown_converter
        @markdown_converter ||= @site.find_converter_instance(CONVERTER_CLASS)
      end

      # generator helpers

      def new_page(path, filename, content)
        new_file = PageWithoutAFile.new(@site, __dir__, "", filename)
        new_file.content = content
        new_file.data["layout"] = nil
        new_file.data["permalink"] = File.join(path, filename)
        @site.pages << new_file unless file_exists?(filename)
        return new_file
      end

      def register_static_file(static_file)
        # tests fail without manually adding the static file, but actual site builds seem to do ok
        # ...although there does seem to be a race condition which causes a rebuild to be necessary in order to detect the graph data file
        if $graph_conf.testing
          @site.static_files << static_file if !@site.static_files.include?(static_file)
        end
      end

      # json population helpers

      def set_neighbors(json_nodes, json_links)
        json_links.each do |json_link|
          source_node = json_nodes.detect { |n| n[:id] == json_link[:source] }
          target_node = json_nodes.detect { |n| n[:id] == json_link[:target] }

          source_node[:neighbors][:nodes] << target_node[:id]
          target_node[:neighbors][:nodes] << source_node[:id]

          source_node[:neighbors][:links] << json_link
          target_node[:neighbors][:links] << json_link
        end
      end

      def set_relatives(json_nodes, json_links)
        # TODO: json nodes have relative_url, but node.id's/urls are doc urls.
        json_nodes.each do |json_node|
          ancestor_node_ids, descendent_node_ids = @site.tree.get_all_relative_ids(json_node[:id])
          relative_node_ids = ancestor_node_ids.concat(descendent_node_ids)
          json_node[:relatives][:nodes] = relative_node_ids if !relative_node_ids.nil?

          # include current node when filtering for links along entire relative lineage
          lineage_ids = relative_node_ids.concat([json_node[:id]])

          json_relative_links = json_links.select { |l| lineage_ids.include?(l[:source]) && lineage_ids.include?(l[:target]) }
          json_node[:relatives][:links] = json_relative_links if !json_relative_links.nil?
        end
      end

      # json generation helpers

      def generate_json_net_web()
        net_web_nodes, net_web_links = [], []

        @md_docs.each do |doc|
          if !$graph_conf.excluded?(doc.type)

            Jekyll.logger.debug "Processing graph nodes for doc: ", doc.data['title']
            #
            # missing nodes
            #
            @site.link_index.index[doc.url].missing.each do |missing_link_name|
              if net_web_nodes.none? { |node| node[:id] == missing_link_name }
                Jekyll.logger.warn "Net-Web node missing: ", missing_link_name
                Jekyll.logger.warn " in: ", doc.data['title']
                net_web_nodes << {
                  id: missing_link_name, # an id is necessary for link targets
                  url: '',
                  label: missing_link_name,
                  neighbors: {
                    nodes: [],
                    links: [],
                  },
                }
                net_web_links << {
                  source: doc.url,
                  target: missing_link_name,
                }
              end
            end
            #
            # existing nodes
            #
            net_web_nodes << {
              # TODO: when using real ids, be sure to convert id to string (to_s)
              id: doc.url,
              url: relative_url(doc.url),
              label: doc.data['title'],
              neighbors: {
                nodes: [],
                links: [],
              },
            }
            # TODO: this link calculation ends up with duplicates -- re-visit this later.
            @site.link_index.index[doc.url].attributes.each do |link| # link = { 'type' => str, 'urls' => [str, str, ...] }
              # TODO: Header + Block-level wikilinks
              link['urls'].each do |lu|
                link_no_anchor = lu.match(/([^#]+)/i)[0]
                link_no_baseurl = @site.baseurl.nil? ? link_no_anchor : link_no_anchor.gsub(@site.baseurl, "")
                linked_doc = @md_docs.select{ |d| d.url == link_no_baseurl }
                if !linked_doc.nil? && linked_doc.size == 1 && !$graph_conf.excluded?(linked_doc.first.type)
                  # TODO: add link['type'] to d3 graph
                  net_web_links << {
                    source: doc.url,
                    target: linked_doc.first.url,
                  }
                end
              end
            end
            @site.link_index.index[doc.url].forelinks.each do |link| # link = { 'type' => str, 'url' => str }
              # TODO: Header + Block-level wikilinks
              link_no_anchor = link['url'].match(/([^#]+)/i)[0]
              link_no_baseurl = @site.baseurl.nil? ? link_no_anchor : link_no_anchor.gsub(@site.baseurl, "")
              linked_doc = @md_docs.select{ |d| d.url == link_no_baseurl }
              if !linked_doc.nil? && linked_doc.size == 1 && !$graph_conf.excluded?(linked_doc.first.type)
                # TODO: add link['type'] to d3 graph
                net_web_links << {
                  source: doc.url,
                  target: linked_doc.first.url,
                }
              end
            end

          end
        end

        return net_web_nodes, net_web_links
      end

      def generate_json_tree(node, json_parent="", tree_nodes=[], tree_links=[])
        #
        # missing nodes
        #
        if node.missing
          Jekyll.logger.warn("Document for tree node missing: ", node.namespace)

          leaf = node.namespace.split('.').pop()
          missing_node = {
            id: node.namespace,
            label: leaf.gsub('-', ' '),
            namespace: node.namespace,
            url: "",
            relatives: {
              nodes: [],
              links: [],
            },
          }
          tree_nodes << missing_node
          if !json_parent.empty?
            tree_links << {
              source: json_parent[:id],
              target: node.namespace,
            }
          end
          json_parent = missing_node
        #
        # existing nodes
        #
        else
          existing_node = {
            id: node.url,
            label: node.title,
            namespace: node.namespace,
            url: relative_url(node.url),
            relatives: {
              nodes: [],
              links: [],
            },
          }
          tree_nodes << existing_node
          if !json_parent.empty?
            tree_links << {
              source: json_parent[:id],
              target: node.url,
            }
          end
          json_parent = existing_node
        end
        node.children.each do |child|
          self.generate_json_tree(child, json_parent, tree_nodes, tree_links)
        end
        return tree_nodes, tree_links
      end
    end

  end
end