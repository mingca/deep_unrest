# frozen_string_literal: true

module DeepUnrest
  module Read
    # def self.map_included(params, addr)
    # params[:include].map { |k, v| create_read_mappings({ "#{k}": v }, [*addr, :include]) }
    # end

    def self.create_read_mappings(params, addr = [])
      return unless params
      params.map do |k, v|
        resource_addr = [*addr, k]
        uuid = SecureRandom.uuid
        v[:uuid] = uuid
        [{ klass: k.singularize.classify.constantize,
           policy: "#{k.singularize.classify}Policy".constantize,
           resource: "#{k.singularize.classify}Resource".constantize,
           scope_type: :index,
           addr: resource_addr,
           key: k.camelize(:lower),
           uuid: uuid,
           query: deep_underscore_keys(v) },
         *create_read_mappings(v[:include], [*resource_addr, :include])]
      end.flatten.compact
    end

    def self.plural?(str)
      str.pluralize == str && str.singularize != str
    end

    def self.serialize_result(ctx, item)
      JSONAPI::ResourceSerializer.new(item[:resource],
                                      fields: {
                                        "#{item[:key].pluralize}": item[:query][:fields].map(&:underscore).map(&:to_sym)
                                      }).serialize_to_hash(item[:resource].new(item[:record], ctx))[:data]
    end

    def self.serialize_results(ctx, data)
      data.each do |item|
        item[:serialized_result] = serialize_result(ctx, item)
      end
    end

    def self.deep_underscore_keys(query)
      query.deep_transform_keys! do |key|
        k = begin
              key.to_s.underscore
            rescue StandardError
              key
            end
        begin
          k.to_sym
        rescue StandardError
          key
        end
      end
    end

    def self.resolve_conditions(query, parent_context)
      if query.is_a? Array
        query.each { |item| resolve_conditions(item, parent_context) }
      elsif query.is_a? Hash
        query.each do |k, v|
          next unless v.is_a? Hash
          if v[:from_context]
            name, attr = v[:from_context].split('.')
            next unless parent_context[name]
            query[k] = parent_context[name].send(attr.underscore)
          else
            resolve_conditions(v, parent_context)
          end
        end
      end
      query
    end

    def self.recurse_included_queries(item, mappings, parent_context, included, meta, addr)
      return unless item[:query].key?(:include)
      item[:query][:include].each do |_k, v|
        next_context = parent_context.clone
        next_context[item[:key].singularize] = item[:record]
        next_mapping = mappings.find { |m| m[:uuid] == v[:uuid] }.clone
        execute_query(next_mapping, mappings, next_context, included, meta, addr, item)
      end
    end

    def self.query_item(mapping, mappings, parent_context, included, meta, addr, _parent)
      query = resolve_conditions(mapping[:query].deep_dup, parent_context)
      raise DeepUnrest::InvalidQuery unless query[:id] || query[:find]
      record = if query.key?(:id)
                 mapping[:scope].find(query[:id]) if query.key?(:id)
               else
                 mapping[:scope].find_by!(query[:find])
               end

      next_addr = [*addr, mapping[:key]]

      result = {
        **mapping,
        addr: next_addr,
        record: record
      }

      included << result

      recurse_included_queries(result, mappings, parent_context, included, meta, [*next_addr, :included])
    end

    def self.get_paginator(query, _parent)
      opts = query.dig(:paginate) || {}
      params = ActionController::Parameters.new(opts)

      case params[:type]
      when :offset
        OffsetPaginator.new(params)
      else
        PagedPaginator.new(params)
      end
    end

    def self.query_list(item, mappings, parent_context, included, meta, addr, parent)
      base_query = item[:query].deep_dup
      extension = base_query.dig(:extend, parent&.fetch(:record)&.id&.to_s) || {}
      query = resolve_conditions(base_query.deep_merge(extension),
                                 parent_context)

      paginator = get_paginator(query, parent)
      resource = item[:resource]

      # monkey patch the resource to only show authorized records
      def resource.records_base(_opts)
        item[:scope]
      end

      # results = resource.find(query[:filter], paginator: paginator,
                                              # sort_criteria: query[:sort])

      processor = JSONAPI::Processor.new(item[:resource],
                                         :find,
                                         filters: query[:filter] || {},
                                         sort_criteria: query[:sort],
                                         paginator: paginator)

      jsonapi_result = processor.process

      meta << {
        addr: [*addr, item[:key], 'meta'],
        serialized_result: {
          paginationParams: jsonapi_result.pagination_params,
          recordCount: jsonapi_result.record_count,
        }
      }

      jsonapi_result.resources.each_with_index do |record, i|
        next_addr = [*addr, item[:key], 'data[]', i]
        result = {
          **item,
          addr: next_addr,
          record: record._model
        }

        included << result
        recurse_included_queries(result, mappings, parent_context, included, meta, [*next_addr, :included])
      end
    end

    def self.get_query_type(item)
      return :detail unless plural?(item[:key])
      :list
    end

    def self.execute_query(item, mappings, parent_context, included, meta, addr, parent = nil)
      if get_query_type(item) == :list
        query_list(item, mappings, parent_context, included, meta, addr, parent)
      else
        query_item(item, mappings, parent_context, included, meta, addr, parent)
      end
    end

    def self.execute_queries(mappings, parent_context = {}, included = [], meta = [], addr = [])
      mappings.select { |m| m[:addr].size == 1 }.each do |item|
        item[:results] = execute_query(item, mappings, parent_context, included, meta, addr)
      end
      [included, meta]
    end

    def self.set_attr(hash, path, val, cursor = nil)
      cursor ||= hash
      key = path.shift

      if path.empty?
        case cursor
        when Array
          cursor << val
        when Hash
          cursor[key] = val
        end
        return hash
      end

      next_cursor = case key
                    when /\[\]$/
                      cursor[key.gsub('[]', '')] ||= []
                    else
                      cursor[key] ||= {}
                    end

      set_attr(hash, path, val, next_cursor)
    end

    def self.format_response(mappings)
      response = {}
      mappings.each do |mapping|
        set_attr(response, mapping[:addr], mapping[:serialized_result])
      end
      response
    end

    def self.collect_authorized_scopes(mappings, user)
      mappings.each do |mapping|
        mapping[:scope] = DeepUnrest.authorization_strategy.get_authorized_scope(user, mapping[:klass])
      end
    end

    def self.read(ctx, params, user)
      # create mappings for assembly / disassembly
      mappings = create_read_mappings(params.to_unsafe_h)

      # authorize user for requested scope(s)
      DeepUnrest.authorization_strategy.authorize(mappings, user).flatten

      # collect authorized scopes
      collect_authorized_scopes(mappings, user)

      # read data
      data, meta = execute_queries(mappings)

      # serialize using JSONAPI resource serializers
      serialize_results(ctx, data)

      # assemble results into something resembling shape of request
      format_response([*data, *meta])
    end
  end
end