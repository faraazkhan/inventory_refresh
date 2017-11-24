module ManagerRefresh
  # For more usage examples please follow spec examples in
  # * spec/models/manager_refresh/save_inventory/single_inventory_collection_spec.rb
  # * spec/models/manager_refresh/save_inventory/acyclic_graph_of_inventory_collections_spec.rb
  # * spec/models/manager_refresh/save_inventory/graph_of_inventory_collections_spec.rb
  # * spec/models/manager_refresh/save_inventory/graph_of_inventory_collections_targeted_refresh_spec.rb
  # * spec/models/manager_refresh/save_inventory/strategies_and_references_spec.rb
  #
  # @example storing Vm model data into the DB
  #
  #   @ems = ManageIQ::Providers::BaseManager.first
  #   puts @ems.vms.collect(&:ems_ref) # => []
  #
  #   # Init InventoryCollection
  #   vms_inventory_collection = ::ManagerRefresh::InventoryCollection.new(
  #     :model_class => ManageIQ::Providers::CloudManager::Vm, :parent => @ems, :association => :vms
  #   )
  #
  #   # Fill InventoryCollection with data
  #   # Starting with no vms, lets add vm1 and vm2
  #   vms_inventory_collection.build(:ems_ref => "vm1", :name => "vm1")
  #   vms_inventory_collection.build(:ems_ref => "vm2", :name => "vm2")
  #
  #   # Save InventoryCollection to the db
  #   ManagerRefresh::SaveInventory.save_inventory(@ems, [vms_inventory_collection])
  #
  #   # The result in the DB is that vm1 and vm2 were created
  #   puts @ems.vms.collect(&:ems_ref) # => ["vm1", "vm2"]
  #
  # @example In another refresh, vm1 does not exist anymore and vm3 was added
  #   # Init InventoryCollection
  #   vms_inventory_collection = ::ManagerRefresh::InventoryCollection.new(
  #     :model_class => ManageIQ::Providers::CloudManager::Vm, :parent => @ems, :association => :vms
  #   )
  #
  #   # Fill InventoryCollection with data
  #   vms_inventory_collection.build(:ems_ref => "vm2", :name => "vm2")
  #   vms_inventory_collection.build(:ems_ref => "vm3", :name => "vm3")
  #
  #   # Save InventoryCollection to the db
  #   ManagerRefresh::SaveInventory.save_inventory(@ems, [vms_inventory_collection])
  #
  #   # The result in the DB is that vm1 was deleted, vm2 was updated and vm3 was created
  #   puts @ems.vms.collect(&:ems_ref) # => ["vm2", "vm3"]
  #
  class InventoryCollection
    # @return [Boolean] true if this collection is already saved into the DB. E.g. InventoryCollections with
    #   DB only strategy are marked as saved. This causes InventoryCollection not being a dependency for any other
    #   InventoryCollection, since it is already persisted into the DB.
    attr_accessor :saved

    # @return [Array<InventoryObject>] objects of the InventoryCollection in an Array
    attr_accessor :data

    # @return [Hash] InventoryObject objects of the InventoryCollection indexed in a Hash by their :manager_ref.
    attr_accessor :data_index

    # @return [Set] A set of InventoryObjects manager_uuids, which tells us which InventoryObjects were
    #         referenced by other InventoryObjects using a lazy_find.
    attr_accessor :references

    # @return [Set] A set of InventoryObject attributes names, which tells us InventoryObject attributes
    #         were referenced by other InventoryObject objects using a lazy_find with :key.
    attr_accessor :attribute_references

    # @return [Boolean] A true value marks that we collected all the data of the InventoryCollection,
    #         meaning we also collected all the references.
    attr_accessor :data_collection_finalized

    # If present, InventoryCollection switches into delete_complement mode, where it will
    # delete every record from the DB, that is not present in this list. This is used for the batch processing,
    # where we don't know which InventoryObject should be deleted, but we know all manager_uuids of all
    # InventoryObject objects that exists in the provider.
    #
    # @return [Array, nil] nil or a list of all :manager_uuids that are present in the Provider's InventoryCollection.
    attr_accessor :all_manager_uuids

    # @return [Set] A set of InventoryCollection objects that depends on this InventoryCollection object.
    attr_accessor :dependees

    # @return [Array<Symbol>] names of InventoryCollection objects or InventoryCollection objects.
    #         If symbols are used, those will be transformed to InventoryCollection objects by the Scanner.
    attr_accessor :parent_inventory_collections

    attr_reader :model_class, :strategy, :attributes_blacklist, :attributes_whitelist, :custom_save_block, :parent,
                :internal_attributes, :delete_method, :dependency_attributes, :manager_ref,
                :association, :complete, :update_only, :transitive_dependency_attributes, :custom_manager_uuid,
                :custom_db_finder, :check_changed, :arel, :builder_params,
                :inventory_object_attributes, :name, :saver_strategy, :manager_uuids,
                :skeletal_manager_uuids, :targeted_arel, :targeted, :manager_ref_allowed_nil, :use_ar_object,
                :secondary_refs, :created_records, :updated_records, :deleted_records,
                :custom_reconnect_block, :batch_extra_attributes

    delegate :each, :size, :to => :to_a

    attr_reader :index_proxy
    delegate :find, :find_by, :lazy_find, :lazy_find_by, :primary_index, :store_indexes_for_inventory_object, :to => :index_proxy

    # @param model_class [Class] A class of an ApplicationRecord model, that we want to persist into the DB or load from
    #        the DB.
    # @param manager_ref [Array] Array of Symbols, that are keys of the InventoryObject's data, inserted into this
    #        InventoryCollection. Using these keys, we need to be able to uniquely identify each of the InventoryObject
    #        objects inside.
    # @param association [Symbol] A Rails association callable on a :parent attribute is used for comparing with the
    #        objects in the DB, to decide if the InventoryObjects will be created/deleted/updated or used for obtaining
    #        the data from a DB, if a DB strategy is used. It returns objects of the :model_class class or its sub STI.
    # @param parent [ApplicationRecord] An ApplicationRecord object that has a callable :association method returning
    #        the objects of a :model_class.
    # @param strategy [Symbol] A strategy of the InventoryCollection that will be used for saving/loading of the
    #        InventoryObject objects.
    #        Allowed strategies are:
    #         - nil => InventoryObject objects of the InventoryCollection will be saved to the DB, only these objects
    #                  will be referable from the other InventoryCollection objects.
    #         - :local_db_cache_all => Loads InventoryObject objects from the database, it loads all the objects that
    #                                  are a result of a [:custom_db_finder, <:parent>.<:association>, :arel] taking
    #                                  first defined in this order. This strategy will not save any objects in the DB.
    #         - :local_db_find_references => Loads InventoryObject objects from the database, it loads only objects that
    #                                        were referenced by the other InventoryCollections using a filtered result
    #                                        of a [:custom_db_finder, <:parent>.<:association>, :arel] taking first
    #                                        defined in this order. This strategy will not save any objects in the DB.
    #         - :local_db_find_missing_references => InventoryObject objects of the InventoryCollection will be saved to
    #                                                the DB. Then if we reference an object that is not present, it will
    #                                                load them from the db using :local_db_find_references strategy.
    # @param custom_save_block [Proc] A custom lambda/proc for persisting in the DB, for cases where it's not enough
    #        to just save every InventoryObject inside by the defined rules and default saving algorithm.
    #
    #        Example1 - saving SomeModel in my own ineffective way :-) :
    #
    #            custom_save = lambda do |_ems, inventory_collection|
    #              inventory_collection.each |inventory_object| do
    #                hash = inventory_object.attributes # Loads possible dependencies into saveable hash
    #                obj = SomeModel.find_by(:attr => hash[:attr]) # Note: doing find_by for many models produces N+1
    #                                                              # queries, avoid this, this is just a simple example :-)
    #                obj.update_attributes(hash) if obj
    #                obj ||= SomeModel.create(hash)
    #                inventory_object.id = obj.id # If this InventoryObject is referenced elsewhere, we need to store its
    #                                               primary key back to the InventoryObject
    #             end
    #
    #        Example2 - saving parent OrchestrationStack in a more effective way, than the default saving algorithm can
    #        achieve. Ancestry gem requires an ActiveRecord object for association and is not defined as a proper
    #        ActiveRecord association. That leads in N+1 queries in the default saving algorithm, so we can do better
    #        with custom saving for now. The InventoryCollection is defined as a custom dependencies processor,
    #        without its own :model_class and InventoryObjects inside:
    #
    #            ManagerRefresh::InventoryCollection.new({
    #              :association       => :orchestration_stack_ancestry,
    #              :custom_save_block => orchestration_stack_ancestry_save_block,
    #              :dependency_attributes => {
    #                :orchestration_stacks           => [collections[:orchestration_stacks]],
    #                :orchestration_stacks_resources => [collections[:orchestration_stacks_resources]]
    #              }
    #            })
    #
    #        And the lambda is defined as:
    #
    #            orchestration_stack_ancestry_save_block = lambda do |_ems, inventory_collection|
    #              stacks_inventory_collection = inventory_collection.dependency_attributes[:orchestration_stacks].try(:first)
    #
    #              return if stacks_inventory_collection.blank?
    #
    #              stacks_parents = stacks_inventory_collection.data.each_with_object({}) do |x, obj|
    #                parent_id = x.data[:parent].load.try(:id)
    #                obj[x.id] = parent_id if parent_id
    #              end
    #
    #              model_class = stacks_inventory_collection.model_class
    #
    #              stacks_parents_indexed = model_class
    #                                         .select([:id, :ancestry])
    #                                         .where(:id => stacks_parents.values).find_each.index_by(&:id)
    #
    #              model_class
    #                .select([:id, :ancestry])
    #                .where(:id => stacks_parents.keys).find_each do |stack|
    #                parent = stacks_parents_indexed[stacks_parents[stack.id]]
    #                stack.update_attribute(:parent, parent)
    #              end
    #            end
    # @param custom_reconnect_block [Proc] A custom lambda for reconnect logic of previously disconnected records
    #
    #        Example - Reconnect disconnected Vms
    #            ManagerRefresh::InventoryCollection.new({
    #              :association            => :orchestration_stack_ancestry,
    #              :custom_reconnect_block => vms_custom_reconnect_block,
    #            })
    #
    #        And the lambda is defined as:
    #
    #            vms_custom_reconnect_block = lambda do |inventory_collection, inventory_objects_index, attributes_index|
    #              inventory_objects_index.each_slice(1000) do |batch|
    #                Vm.where(:ems_ref => batch.map(&:second).map(&:manager_uuid)).each do |record|
    #                  index = inventory_collection.object_index_with_keys(inventory_collection.manager_ref_to_cols, record)
    #
    #                  # We need to delete the record from the inventory_objects_index and attributes_index, otherwise it
    #                  # would be sent for create.
    #                  inventory_object = inventory_objects_index.delete(index)
    #                  hash             = attributes_index.delete(index)
    #
    #                  record.assign_attributes(hash.except(:id, :type))
    #                  if !inventory_collection.check_changed? || record.changed?
    #                    record.save!
    #                    inventory_collection.store_updated_records(record)
    #                  end
    #
    #                  inventory_object.id = record.id
    #                end
    #              end
    # @param delete_method [Symbol] A delete method that will be used for deleting of the InventoryObject, if the
    #        object is marked for deletion. A default is :destroy, the instance method must be defined on the
    #        :model_class.
    # @param dependency_attributes [Hash] Manually defined dependencies of this InventoryCollection. We can use this
    #        by manually place the InventoryCollection into the graph, to make sure the saving is invoked after the
    #        dependencies were saved. The dependencies itself are InventoryCollection objects. For a common use-cases
    #        we do not need to define dependencies manually, since those are inferred automatically by scanning of the
    #        data.
    #
    #        Example:
    #          :dependency_attributes => {
    #            :orchestration_stacks           => [collections[:orchestration_stacks]],
    #            :orchestration_stacks_resources => [collections[:orchestration_stacks_resources]]
    #          }
    #        This example is used in Example2 of the <param custom_save_block> and it means that our :custom_save_block
    #        will be invoked after the InventoryCollection :orchestration_stacks and :orchestration_stacks_resources
    #        are saved.
    # @param attributes_blacklist [Array] Attributes we do not want to include into saving. We cannot blacklist an
    #        attribute that is needed for saving of the object.
    #        Note: attributes_blacklist is also used for internal resolving of the cycles in the graph.
    #
    #        In the Example2 of the <param custom_save_block>, we have a custom saving code, that saves a :parent
    #        attribute of the OrchestrationStack. That means we don't want that attribute saved as a part of
    #        InventoryCollection for OrchestrationStack, so we would set :attributes_blacklist => [:parent]. Then the
    #        :parent will be ignored while saving.
    # @param attributes_whitelist [Array] Same usage as the :attributes_blacklist, but defining full set of attributes
    #        that should be saved. Attributes that are part of :manager_ref and needed validations are automatically
    #        added.
    # @param complete [Boolean] By default true, :complete is marking we are sending a complete dataset and therefore
    #        we can create/update/delete the InventoryObject objects. If :complete is false we will only do
    #        create/update without delete.
    # @param update_only [Boolean] By default false. If true we only update the InventoryObject objects, if false we do
    #        create/update/delete.
    # @param check_changed [Boolean] By default true. If true, before updating the InventoryObject, we call Rails
    #        'changed?' method. This can optimize speed of updates heavily, but it can fail to recognize the change for
    #        e.g. Ancestry and Relationship based columns. If false, we always update the InventoryObject.
    # @param custom_manager_uuid [Proc] A custom way of getting a unique :manager_uuid of the object using :manager_ref.
    #        In a complex cases, where part of the :manager_ref is another InventoryObject, we cannot infer the
    #        :manager_uuid, if it comes from the DB. In that case, we need to provide a way of getting the :manager_uuid
    #        from the DB.
    #
    #        Example: Given
    #                    InventoryCollection.new({
    #                      :model_class         => ::Hardware,
    #                      :manager_ref         => [:vm_or_template],
    #                      :association         => :hardwares,
    #                      :custom_manager_uuid => custom_manager_uuid
    #                    })
    #
    #        The :manager_ref => [:vm_or_template] points to another InventoryObject and we need to get a
    #        :manager_uuid of that object. But if InventoryCollection was loaded from the DB, we can access the
    #        :manager_uuid only by loading it from the DB as:
    #             custom_manager_uuid = lambda do |hardware|
    #               [hardware.vm_or_template.ems_ref]
    #             end
    #
    #        Note: make sure to combine this with :custom_db_finder, to avoid N+1 queries being done, which we can
    #        achieve by .includes(:vm_or_template). See Example in <param :custom_db_finder>.
    # @param custom_db_finder [Proc] A custom way of getting the InventoryCollection out of the DB in a case of any DB
    #        based strategy. This should be used in a case of complex query needed for e.g. targeted refresh or as an
    #        optimization for :custom_manager_uuid.
    #
    #        Example, we solve N+1 issue from Example <param :custom_manager_uuid> as well as a selection used for
    #        targeted refresh getting Hardware object from the DB instead of the API:
    #        Having
    #                 InventoryCollection.new({
    #                   :model_class         => ::Hardware,
    #                   :manager_ref         => [:vm_or_template],
    #                   :association         => :hardwares,
    #                   :custom_manager_uuid => custom_manager_uuid,
    #                   :custom_db_finder    => custom_db_finder
    #                 })
    #
    #        We need a custom_db_finder:
    #          custom_db_finder = lambda do |inventory_collection, selection, _projection|
    #            relation = inventory_collection.parent.send(inventory_collection.association)
    #                                           .includes(:vm_or_template)
    #                                           .references(:vm_or_template)
    #            relation = relation.where(:vms => {:ems_ref => selection[:vm_or_template]}) unless selection.blank?
    #            relation
    #          end
    #
    #        Which solved 2 things for us:
    #        - hardware.vm_or_template.ems_ref in a :custom_manager_uuid doesn't do N+1 queries anymore. To handle
    #          just this problem, it would be enough to return
    #          inventory_collection.parent.send(inventory_collection.association).includes?(:vm_or_template)
    #        - We can use :local_db_find_references strategy on this inventory collection, which could not be used
    #          by default, since the selection needs a complex join, to be able to filter by the :vm_or_template
    #          ems_ref.
    #          We could still use a :local_db_cache_all strategy though, which doesn't do any selection and loads
    #          all :hardwares from the DB.
    # @param arel [ActiveRecord::Associations::CollectionProxy|Arel::SelectManager] Instead of :parent and :association
    #        we can provide Arel directly to say what records should be compared to check if InventoryObject will be
    #        doing create/update/delete.
    #
    #        Example:
    #        for a targeted refresh, we want to delete/update/create only a list of vms specified with a list of
    #        ems_refs:
    #            :arel => manager.vms.where(:ems_ref => manager_refs)
    #        Then we want to do the same for the hardwares of only those vms:
    #             :arel => manager.hardwares.joins(:vm_or_template).where(
    #               'vms' => {:ems_ref => manager_refs}
    #             )
    #        And etc. for the other Vm related records.
    # @param builder_params [Hash] A hash of an attributes that will be added to every inventory object created by
    #        inventory_collection.build(hash)
    #
    #        Example: Given
    #          inventory_collection = InventoryCollection.new({
    #            :model_class    => ::Vm,
    #            :arel           => @ems.vms,
    #            :builder_params => {:ems_id => 10}
    #          })
    #        And building the inventory_object like:
    #            inventory_object = inventory_collection.build(:ems_ref => "vm_1", :name => "vm1")
    #        The inventory_object.data will look like:
    #            {:ems_ref => "vm_1", :name => "vm1", :ems_id => 10}
    # @param inventory_object_attributes [Array] Array of attribute names that will be exposed as readers/writers on the
    #        InventoryObject objects inside.
    #
    #        Example: Given
    #                   inventory_collection = InventoryCollection.new({
    #                      :model_class                 => ::Vm,
    #                      :arel                        => @ems.vms,
    #                      :inventory_object_attributes => [:name, :label]
    #                    })
    #        And building the inventory_object like:
    #          inventory_object = inventory_collection.build(:ems_ref => "vm1", :name => "vm1")
    #        We can use inventory_object_attributes as setters and getters:
    #          inventory_object.name = "Name"
    #          inventory_object.label = inventory_object.name
    #        Which would be equivalent to less nicer way:
    #          inventory_object[:name] = "Name"
    #          inventory_object[:label] = inventory_object[:name]
    #        So by using inventory_object_attributes, we will be guarding the allowed attributes and will have an
    #        explicit list of allowed attributes, that can be used also for documentation purposes.
    # @param name [Symbol] A unique name of the InventoryCollection under a Persister. If not provided, the :association
    #        attribute is used. If :association is nil as well, the :name will be inferred from the :model_class.
    # @param saver_strategy [Symbol] A strategy that will be used for InventoryCollection persisting into the DB.
    #        Allowed saver strategies are:
    #        - :default => Using Rails saving methods, this way is not safe to run in multiple workers concurrently,
    #          since it will lead to non consistent data.
    #        - :batch => Using batch SQL queries, this way is not safe to run in multiple workers
    #          concurrently, since it will lead to non consistent data.
    #        - :concurrent_safe => This method is designed for concurrent saving. It uses atomic upsert to avoid
    #          data duplication and it uses timestamp based atomic checks to avoid new data being overwritten by the
    #          the old data.
    #        - :concurrent_safe_batch => Same as :concurrent_safe, but the upsert/update queries are executed as
    #          batched SQL queries, instead of sending 1 query per record.
    # @param parent_inventory_collections [Array] Array of symbols having a name of the
    #        ManagerRefresh::InventoryCollection objects, that serve as parents to this InventoryCollection. Then this
    #        InventoryCollection completeness will be encapsulated by the parent_inventory_collections :manager_uuids
    #        instead of this InventoryCollection :manager_uuids.
    # @param manager_uuids [Array] Array of manager_uuids of the InventoryObjects we want to create/update/delete. Using
    #        this attribute, the db_collection_for_comparison will be automatically limited by the manager_uuids, in a
    #        case of a simple relation. In a case of a complex relation, we can leverage :manager_uuids in a
    #        custom :targeted_arel.
    # @param all_manager_uuids [Array] Array of all manager_uuids of the InventoryObjects. With the :targeted true,
    #        having this parameter defined will invoke only :delete_method on a complement of this set, making sure
    #        the DB has only this set of data after. This :attribute serves for deleting of top level
    #        InventoryCollections, i.e. InventoryCollections having parent_inventory_collections nil. The deleting of
    #        child collections is already handled by the scope of the parent_inventory_collections and using Rails
    #        :dependent => :destroy,
    # @param targeted_arel [Proc] A callable block that receives this InventoryCollection as a first argument. In there
    #        we can leverage a :parent_inventory_collections or :manager_uuids to limit the query based on the
    #        manager_uuids available.
    #        Example:
    #          targeted_arel = lambda do |inventory_collection|
    #            # Getting ems_refs of parent :vms and :miq_templates
    #            manager_uuids = inventory_collection.parent_inventory_collections.collect(&:manager_uuids).flatten
    #            inventory_collection.db_collection_for_comparison.hardwares.joins(:vm_or_template).where(
    #              'vms' => {:ems_ref => manager_uuids}
    #            )
    #          end
    #
    #          inventory_collection = InventoryCollection.new({
    #                                   :model_class                 => ::Hardware,
    #                                   :association                 => :hardwares,
    #                                   :parent_inventory_collection => [:vms, :miq_templates],
    #                                   :targeted_arel               => targeted_arel,
    #                                 })
    # @param targeted [Boolean] True if the collection is targeted, in that case it will be leveraging :manager_uuids
    #        :parent_inventory_collections and :targeted_arel to save a subgraph of a data.
    # @param manager_ref_allowed_nil [Array] Array of symbols having manager_ref columns, that are a foreign key an can
    #        be nil. Given the table are shared by many providers, it can happen, that the table is used only partially.
    #        Then it can happen we want to allow certain foreign keys to be nil, while being sure the referential
    #        integrity is not broken. Of course the DB Foreign Key can't be created in this case, so we should try to
    #        avoid this usecase by a proper modeling.
    # @param use_ar_object [Boolean] True or False. Whether we need to initialize AR object as part of the saving
    #        it's needed if the model have special setters, serialize of columns, etc. This setting is relevant only
    #        for the batch saver strategy.
    # @param batch_extra_attributes [Array] Array of symbols marking which extra attributes we want to store into the
    #        db. These extra attributes might be a product of :use_ar_object assignment and we need to specify them
    #        manually, if we want to use a batch saving strategy and we have models that populate attributes as a side
    #        effect.
    def initialize(model_class: nil, manager_ref: nil, association: nil, parent: nil, strategy: nil,
                   custom_save_block: nil, delete_method: nil, dependency_attributes: nil,
                   attributes_blacklist: nil, attributes_whitelist: nil, complete: nil, update_only: nil,
                   check_changed: nil, custom_manager_uuid: nil, custom_db_finder: nil, arel: nil, builder_params: {},
                   inventory_object_attributes: nil, name: nil, saver_strategy: nil,
                   parent_inventory_collections: nil, manager_uuids: [], all_manager_uuids: nil, targeted_arel: nil,
                   targeted: nil, manager_ref_allowed_nil: nil, secondary_refs: {}, use_ar_object: nil,
                   custom_reconnect_block: nil, batch_extra_attributes: [])
      @model_class            = model_class
      @manager_ref            = manager_ref || [:ems_ref]
      @secondary_refs         = secondary_refs
      @custom_manager_uuid    = custom_manager_uuid
      @custom_db_finder       = custom_db_finder
      @association            = association || []
      @parent                 = parent || nil
      @arel                   = arel
      @dependency_attributes  = dependency_attributes || {}
      @strategy               = process_strategy(strategy)
      @delete_method          = delete_method || :destroy
      @custom_save_block      = custom_save_block
      @custom_reconnect_block = custom_reconnect_block
      @check_changed          = check_changed.nil? ? true : check_changed
      @internal_attributes    = [:__feedback_edge_set_parent, :__parent_inventory_collections]
      @complete               = complete.nil? ? true : complete
      @update_only            = update_only.nil? ? false : update_only
      @builder_params         = builder_params
      @name                   = name || association || model_class.to_s.demodulize.tableize
      @saver_strategy         = process_saver_strategy(saver_strategy)
      @use_ar_object          = use_ar_object || false
      @batch_extra_attributes = batch_extra_attributes

      @manager_ref_allowed_nil = manager_ref_allowed_nil || []

      # Targeted mode related attributes
      @manager_uuids                = Set.new.merge(manager_uuids)
      @all_manager_uuids            = all_manager_uuids
      @parent_inventory_collections = parent_inventory_collections
      @skeletal_manager_uuids       = Set.new.merge(manager_uuids)
      @targeted_arel                = targeted_arel
      @targeted                     = !!targeted

      @inventory_object_attributes = inventory_object_attributes

      @data                             = []
      @saved                          ||= false
      @attributes_blacklist             = Set.new
      @attributes_whitelist             = Set.new
      @transitive_dependency_attributes = Set.new
      @dependees                        = Set.new
      @references                       = Set.new
      @attribute_references             = Set.new

      @index_proxy = ManagerRefresh::InventoryCollection::Index::Proxy.new(self, secondary_refs)

      @data_collection_finalized = false

      @created_records = []
      @updated_records = []
      @deleted_records = []

      blacklist_attributes!(attributes_blacklist) if attributes_blacklist.present?
      whitelist_attributes!(attributes_whitelist) if attributes_whitelist.present?

      validate_inventory_collection!
    end

    def store_created_records(records)
      @created_records.concat(records_identities(records))
    end

    def store_updated_records(records)
      @updated_records.concat(records_identities(records))
    end

    def store_deleted_records(records)
      @deleted_records.concat(records_identities(records))
    end

    def to_a
      data
    end

    def from_raw_data(inventory_objects_data, available_inventory_collections)
      inventory_objects_data.each do |inventory_object_data|
        hash = inventory_object_data.each_with_object({}) do |(key, value), result|
          result[key.to_sym] = if value.kind_of?(Array)
                                 value.map { |x| from_raw_value(x, available_inventory_collections) }
                               else
                                 from_raw_value(value, available_inventory_collections)
                               end
        end
        build(hash)
      end
    end

    def from_raw_value(value, available_inventory_collections)
      if value.kind_of?(Hash) && (value['type'] || value[:type]) == "ManagerRefresh::InventoryObjectLazy"
        value.transform_keys!(&:to_s)
      end

      if value.kind_of?(Hash) && value['type'] == "ManagerRefresh::InventoryObjectLazy"
        inventory_collection = available_inventory_collections[value['inventory_collection_name'].try(:to_sym)]
        raise "Couldn't build lazy_link #{value} the inventory_collection_name was not found" if inventory_collection.blank?
        inventory_collection.lazy_find(value['ems_ref'], :key => value['key'], :default => value['default'])
      else
        value
      end
    end

    def to_raw_data
      data.map do |inventory_object|
        inventory_object.data.transform_values do |value|
          if inventory_object_lazy?(value)
            value.to_raw_lazy_relation
          elsif value.kind_of?(Array) && (inventory_object_lazy?(value.compact.first) || inventory_object?(value.compact.first))
            value.compact.map(&:to_raw_lazy_relation)
          elsif inventory_object?(value)
            value.to_raw_lazy_relation
          else
            value
          end
        end
      end
    end

    def process_saver_strategy(saver_strategy)
      return :default unless saver_strategy

      case saver_strategy
      when :default, :batch, :concurrent_safe, :concurrent_safe_batch
        saver_strategy
      else
        raise "Unknown InventoryCollection saver strategy: :#{saver_strategy}, allowed strategies are "\
              ":default, :batch, :concurrent_safe and :concurrent_safe_batch"
      end
    end

    def process_strategy(strategy_name)
      return unless strategy_name

      case strategy_name
      when :local_db_cache_all
        self.data_collection_finalized = true
        self.saved = true
      when :local_db_find_references
        self.saved = true
      when :local_db_find_missing_references
      else
        raise "Unknown InventoryCollection strategy: :#{strategy_name}, allowed strategies are :local_db_cache_all, "\
              ":local_db_find_references and :local_db_find_missing_references."
      end
      strategy_name
    end

    def check_changed?
      check_changed
    end

    def use_ar_object?
      use_ar_object
    end

    def complete?
      complete
    end

    def update_only?
      update_only
    end

    def delete_allowed?
      complete? && !update_only?
    end

    def create_allowed?
      !update_only?
    end

    def saved?
      saved
    end

    def saveable?
      dependencies.all?(&:saved?)
    end

    def data_collection_finalized?
      data_collection_finalized
    end

    def inventory_object?(value)
      value.kind_of?(::ManagerRefresh::InventoryObject)
    end

    def inventory_object_lazy?(value)
      value.kind_of?(::ManagerRefresh::InventoryObjectLazy)
    end

    def noop?
      # If this InventoryCollection doesn't do anything. it can easily happen for targeted/batched strategies.
      if targeted?
        if parent_inventory_collections.nil? && manager_uuids.blank? && skeletal_manager_uuids.blank? &&
           all_manager_uuids.nil? && parent_inventory_collections.blank? && custom_save_block.nil?
          # It's a noop Parent targeted InventoryCollection
          true
        elsif !parent_inventory_collections.nil? && parent_inventory_collections.all? { |x| x.manager_uuids.blank? }
          # It's a noop Child targeted InventoryCollection
          true
        else
          false
        end
      elsif data.blank? && !delete_allowed?
        # If we have no data to save and delete is not allowed, we can just skip
        true
      else
        false
      end
    end

    def targeted?
      targeted
    end

    def <<(inventory_object)
      unless primary_index.find(inventory_object.manager_uuid)
        # TODO(lsmola) Abstract InventoryCollection::Data::Storage
        data << inventory_object
        store_indexes_for_inventory_object(inventory_object)
      end
      self
    end
    alias push <<

    def manager_ref_to_cols
      # TODO(lsmola) this should contain the polymorphic _type, otherwise the IC with polymorphic unique key will get
      # conflicts
      # Convert attributes from unique key to actual db cols
      manager_ref.map do |ref|
        association_to_foreign_key_mapping[ref] || ref
      end
    end

    def inventory_object_class
      @inventory_object_class ||= begin
        klass = Class.new(::ManagerRefresh::InventoryObject)
        klass.add_attributes(inventory_object_attributes) if inventory_object_attributes
        klass
      end
    end

    def new_inventory_object(hash)
      manager_ref.each do |x|
        # TODO(lsmola) with some effort, we can do this, but it's complex
        raise "A lazy_find with a :key can't be a part of the manager_uuid" if inventory_object_lazy?(hash[x]) && hash[x].key
      end

      inventory_object_class.new(self, hash)
    end

    def find_or_build(manager_uuid)
      raise "The uuid consists of #{manager_ref.size} attributes, please find_or_build_by method" if manager_ref.size > 1

      find_or_build_by(manager_ref.first => manager_uuid)
    end

    def find_or_build_by(manager_uuid_hash)
      if !manager_uuid_hash.keys.all? { |x| manager_ref.include?(x) } || manager_uuid_hash.keys.size != manager_ref.size
        raise "Allowed find_or_build_by keys are #{manager_ref}"
      end

      # Not using find by since if could take record from db, then any changes would be ignored, since such record will
      # not be stored to DB, maybe we should rethink this?
      primary_index.find(manager_uuid_hash) || build(manager_uuid_hash)
    end

    def build(hash)
      hash = builder_params.merge(hash)
      inventory_object = new_inventory_object(hash)

      uuid = inventory_object.manager_uuid
      # Each InventoryObject must be able to build an UUID, return nil if it can't
      return nil if uuid.blank?
      # Return existing InventoryObject if we have it
      return primary_index.find(uuid) if primary_index.find(uuid)
      # Store new InventoryObject and return it
      push(inventory_object)
      inventory_object
    end

    def filtered_dependency_attributes
      filtered_attributes = dependency_attributes

      if attributes_blacklist.present?
        filtered_attributes = filtered_attributes.reject { |key, _value| attributes_blacklist.include?(key) }
      end

      if attributes_whitelist.present?
        filtered_attributes = filtered_attributes.reject { |key, _value| !attributes_whitelist.include?(key) }
      end

      filtered_attributes
    end

    def fixed_attributes
      if model_class
        presence_validators = model_class.validators.detect { |x| x.kind_of?(ActiveRecord::Validations::PresenceValidator) }
      end
      # Attributes that has to be always on the entity, so attributes making unique index of the record + attributes
      # that have presence validation
      fixed_attributes = manager_ref
      fixed_attributes += presence_validators.attributes unless presence_validators.blank?
      fixed_attributes
    end

    # Returns all unique non saved fixed dependencies
    def fixed_dependencies
      fixed_attrs = fixed_attributes

      filtered_dependency_attributes.each_with_object(Set.new) do |(key, value), fixed_deps|
        fixed_deps.merge(value) if fixed_attrs.include?(key)
      end.reject(&:saved?)
    end

    # Returns all unique non saved dependencies
    def dependencies
      filtered_dependency_attributes.values.map(&:to_a).flatten.uniq.reject(&:saved?)
    end

    def dependency_attributes_for(inventory_collections)
      attributes = Set.new
      inventory_collections.each do |inventory_collection|
        attributes += filtered_dependency_attributes.select { |_key, value| value.include?(inventory_collection) }.keys
      end
      attributes
    end

    def blacklist_attributes!(attributes)
      # The manager_ref attributes cannot be blacklisted, otherwise we will not be able to identify the
      # inventory_object. We do not automatically remove attributes causing fixed dependencies, so beware that without
      # them, you won't be able to create the record.
      self.attributes_blacklist += attributes - (fixed_attributes + internal_attributes)
    end

    def whitelist_attributes!(attributes)
      # The manager_ref attributes always needs to be in the white list, otherwise we will not be able to identify the
      # inventory_object. We do not automatically add attributes causing fixed dependencies, so beware that without
      # them, you won't be able to create the record.
      self.attributes_whitelist += attributes + (fixed_attributes + internal_attributes)
    end

    # @return [InventoryCollection] a shallow copy of InventoryCollection, the copy will share @data of the original
    # collection, otherwise we would be copying a lot of records in memory.
    def clone
      cloned = self.class.new(:model_class           => model_class,
                              :manager_ref           => manager_ref,
                              :association           => association,
                              :parent                => parent,
                              :arel                  => arel,
                              :strategy              => strategy,
                              :saver_strategy        => saver_strategy,
                              :custom_save_block     => custom_save_block,
                              # We want cloned IC to be update only, since this is used for cycle resolution
                              :update_only           => true,
                              # Dependency attributes need to be a hard copy, since those will differ for each
                              # InventoryCollection
                              :dependency_attributes => dependency_attributes.clone)

      cloned.data_index = data_index
      cloned.data       = data
      cloned
    end

    def belongs_to_associations
      model_class.reflect_on_all_associations.select { |x| x.kind_of?(ActiveRecord::Reflection::BelongsToReflection) }
    end

    def association_to_foreign_key_mapping
      return {} unless model_class

      @association_to_foreign_key_mapping ||= belongs_to_associations.each_with_object({}) do |x, obj|
        obj[x.name] = x.foreign_key
      end
    end

    def foreign_key_to_association_mapping
      return {} unless model_class

      @foreign_key_to_association_mapping ||= belongs_to_associations.each_with_object({}) do |x, obj|
        obj[x.foreign_key] = x.name
      end
    end

    def association_to_foreign_type_mapping
      return {} unless model_class

      @association_to_foreign_type_mapping ||= model_class.reflect_on_all_associations.each_with_object({}) do |x, obj|
        obj[x.name] = x.foreign_type if x.polymorphic?
      end
    end

    def foreign_type_to_association_mapping
      return {} unless model_class

      @foreign_type_to_association_mapping ||= model_class.reflect_on_all_associations.each_with_object({}) do |x, obj|
        obj[x.foreign_type] = x.name if x.polymorphic?
      end
    end

    def association_to_base_class_mapping
      return {} unless model_class

      @association_to_base_class_mapping ||= model_class.reflect_on_all_associations.each_with_object({}) do |x, obj|
        obj[x.name] = x.klass.base_class.name unless x.polymorphic?
      end
    end

    def foreign_keys
      return [] unless model_class

      @foreign_keys_cache ||= belongs_to_associations.map(&:foreign_key).map!(&:to_sym)
    end

    def fixed_foreign_keys
      # Foreign keys that are part of a manager_ref must be present, otherwise the record would get lost. This is a
      # minimum check we can do to not break a referential integrity.
      return @fixed_foreign_keys_cache unless @fixed_foreign_keys_cache.nil?

      manager_ref_set = (manager_ref - manager_ref_allowed_nil)
      @fixed_foreign_keys_cache = manager_ref_set.map { |x| association_to_foreign_key_mapping[x] }.compact
      @fixed_foreign_keys_cache += foreign_keys & manager_ref
      @fixed_foreign_keys_cache.map!(&:to_sym)
      @fixed_foreign_keys_cache
    end

    def base_class_name
      return "" unless model_class

      @base_class_name ||= model_class.base_class.name
    end

    def to_s
      whitelist = ", whitelist: [#{attributes_whitelist.to_a.join(", ")}]" unless attributes_whitelist.blank?
      blacklist = ", blacklist: [#{attributes_blacklist.to_a.join(", ")}]" unless attributes_blacklist.blank?

      strategy_name = ", strategy: #{strategy}" if strategy

      name = model_class || association

      "InventoryCollection:<#{name}>#{whitelist}#{blacklist}#{strategy_name}"
    end

    def inspect
      to_s
    end

    def batch_size
      1000
    end

    def batch_size_pure_sql
      10_000
    end

    def hash_index_with_keys(keys, hash)
      stringify_reference(keys.map { |attribute| hash[attribute].to_s })
    end

    def object_index_with_keys(keys, object)
      stringify_reference(keys.map { |attribute| object.public_send(attribute).to_s })
    end

    def stringify_joiner
      "__"
    end

    def stringify_reference(reference)
      reference.join(stringify_joiner)
    end

    def build_multi_selection_condition(hashes, keys = nil)
      keys       ||= manager_ref
      table_name = model_class.table_name
      cond_data  = hashes.map do |hash|
        "(#{keys.map { |x| ActiveRecord::Base.connection.quote(hash[x]) }.join(",")})"
      end.join(",")
      column_names = keys.map { |key| "#{table_name}.#{ActiveRecord::Base.connection.quote_column_name(key)}" }.join(",")

      "(#{column_names}) IN (#{cond_data})"
    end

    def db_collection_for_comparison
      if targeted?
        if targeted_arel.respond_to?(:call)
          targeted_arel.call(self)
        elsif manager_ref.count > 1
          # TODO(lsmola) optimize with ApplicationRecordIterator
          hashes = extract_references(manager_uuids + skeletal_manager_uuids)
          full_collection_for_comparison.where(build_multi_selection_condition(hashes))
        else
          ManagerRefresh::ApplicationRecordIterator.new(
            :inventory_collection => self,
            :manager_uuids_set    => (manager_uuids + skeletal_manager_uuids).to_a.flatten.compact
          )
        end
      else
        full_collection_for_comparison
      end
    end

    def db_collection_for_comparison_for(manager_uuids_set)
      # TODO(lsmola) this should have the build_multi_selection_condition, like in the method above
      full_collection_for_comparison.where(manager_ref.first => manager_uuids_set)
    end

    def db_collection_for_comparison_for_complement_of(manager_uuids_set)
      # TODO(lsmola) this should have the build_multi_selection_condition, like in the method above
      full_collection_for_comparison.where.not(manager_ref.first => manager_uuids_set)
    end

    def full_collection_for_comparison
      return arel unless arel.nil?
      parent.send(association)
    end

    private

    attr_writer :attributes_blacklist, :attributes_whitelist, :db_data_index

    # Returns array of records identities
    def records_identities(records)
      records = [records] unless records.respond_to?(:map)
      records.map { |record| record_identity(record) }
    end

    # Returns a hash with a simple record identity
    def record_identity(record)
      identity = record.try(:[], :id) || record.try(:[], "id") || record.try(:id)
      raise "Cannot obtain identity of the #{record}" if identity.blank?
      {
        :id => identity
      }
    end

    def validate_inventory_collection!
      if @strategy == :local_db_cache_all
        if (manager_ref & association_attributes).present?
          # Our manager_ref unique key contains a reference, that means that index we get from the API and from the
          # db will differ. We need a custom indexing method, so the indexing is correct.
          if custom_manager_uuid.nil?
            raise "The unique key list manager_ref contains a reference, which can't be built automatically when loading"\
                  " the InventoryCollection from the DB, you need to provide a custom_manager_uuid lambda, that builds"\
                  " the correct manager_uuid given a DB record"
          end
        end
      end
    end

    def association_attributes
      # All association attributes and foreign keys of the model class
      model_class.reflect_on_all_associations.map { |x| [x.name, x.foreign_key] }.flatten.compact.map(&:to_sym)
    end
  end
end
