'use strict'

# A simple module to replace `Backbone.sync` with *localStorage*-based
# persistence. Models are given GUIDS, and saved into a JSON object. Simple
# as that.

# Make it easy for collections to sync dirty and destroyed records
# Simply call collection.syncDirtyAndDestroyed()
Backbone.Collection.prototype.syncDirty = ->
  store = localStorage.getItem "#{@url}_dirty"
  ids = (store and store.split(',')) or []
  
  for id in ids
    model = if id.length == 36 then @where(id: id)[0] else @get(parseInt(id))
    model.save()

Backbone.Collection.prototype.syncDestroyed = ->
  store = localStorage.getItem "#{@url}_destroyed"
  ids = (store and store.split(',')) or []
  
  for id in ids
    model = new @model({id: id})
    model.collection = @
    model.destroy()

Backbone.Collection.prototype.syncDirtyAndDestroyed = ->
  @syncDirty()
  @syncDestroyed()

# Generate four random hex digits.
S4 = ->
  (((1 + Math.random()) * 0x10000) | 0).toString(16).substring 1

# Our Store is represented by a single JS object in *localStorage*. Create it
# with a meaningful name, like the name you'd give a table.
class window.Store
  sep: '' # previously '-'

  constructor: (name) ->
    @name = name
    @records = @recordsOn @name

  # Generates an unique id to use when saving new instances into localstorage
  # by default generates a pseudo-GUID by concatenating random hexadecimal.
  # you can overwrite this function to use another strategy
  generateId: ->
    S4() + S4() + '-' + S4() + '-' + S4() + '-' + S4() + '-' + S4() + S4() + S4()
  
  # Save the current state of the **Store** to *localStorage*.
  save: ->
    @localStorageSet @name, @records.join(',')

  # Wrapper to catch "Persistent storage maximum size reached" errors so they
  # don't stop script execution
  localStorageSet: (itemName, itemValue) ->
    try
      localStorage.setItem itemName, itemValue
    catch error
      # console.log "error setting #{itemName} ", error.toString()
  
  recordsOn: (key) ->
    store = localStorage.getItem(key)
    (store and store.split(',')) or []
  
  dirty: (model) ->
    dirtyRecords = @recordsOn @name + '_dirty'
    if not _.include(dirtyRecords, model.id.toString())
      dirtyRecords.push model.id
      @localStorageSet @name + '_dirty', dirtyRecords.join(',')
    model
  
  clean: (model, from) ->
    store = "#{@name}_#{from}"
    dirtyRecords = @recordsOn store
    if _.include dirtyRecords, model.id.toString()
      @localStorageSet store, _.without(dirtyRecords, model.id.toString()).join(',')
    model
    
  destroyed: (model) ->
    destroyedRecords = @recordsOn @name + '_destroyed'
    if not _.include destroyedRecords, model.id.toString()
      destroyedRecords.push model.id
      @localStorageSet @name + '_destroyed', destroyedRecords.join(',')
    model
    
  # Add a model, giving it a (hopefully)-unique GUID, if it doesn't already
  # have an id of it's own.
  create: (model) ->
    if not _.isObject(model) then return model
    if model.attributes? then model = model.attributes
    if not model.id then model.id = @generateId()
    @localStorageSet @name + @sep + model.id, JSON.stringify(model)
    @records.push model.id.toString()
    @save()
    model

  # Update a model by replacing its copy in `this.data`.
  update: (model) ->
    @localStorageSet @name + @sep + model.id, JSON.stringify(model)
    if not _.include(@records, model.id.toString())
      @records.push model.id.toString()
    @save()
    model
  
  clear: ->
    for id in @records
      localStorage.removeItem @name + @sep + id
    @records = []
    @save()
  
  hasDirtyOrDestroyed: ->
    not _.isEmpty(localStorage.getItem(@name + '_dirty')) or not _.isEmpty(localStorage.getItem(@name + '_destroyed'))

  # Retrieve a model from `this.data` by id.
  find: (model) ->
    JSON.parse localStorage.getItem(@name + @sep + model.id)

  # Return the array of all models currently in storage.
  findAll: ->
    for id in @records
      JSON.parse localStorage.getItem(@name + @sep + id)

  # Delete a model from `this.data`, returning it.
  destroy: (model) ->
    localStorage.removeItem @name + @sep + model.id
    @records = _.reject(@records, (record_id) ->
      record_id is model.id.toString()
    )
    @save()
    model

# Override `Backbone.sync` to use delegate to the model or collection's
# *localStorage* property, which should be an instance of `Store`.
localsync = (method, model, options) ->
  store = new Store options.storeName

  response = switch method
    when 'read'
      if model.id then store.find(model) else store.findAll()
    when 'hasDirtyOrDestroyed'
      store.hasDirtyOrDestroyed()
    when 'clear'
      store.clear()
    when 'create'
      model = store.create(model)
      store.dirty(model) if options.dirty
    when 'update'
      store.update(model)
      if options.dirty then store.dirty(model) else store.clean(model, 'dirty')
    when 'delete'
      store.destroy(model)
      if options.dirty
        store.destroyed(model)
      else
        if model.id.toString().length == 36 
          store.clean(model, 'dirty')
        else
          store.clean(model, 'destroyed')
  
  unless options.ignoreCallbacks
    if response
      options.success response
    else
      options.error 'Record not found'
  
  response

# If the value of the named property is a function then invoke it;
# otherwise, return it.
# based on _.result from underscore github
result = (object, property) ->
  return null unless object
  value = object[property]
  if _.isFunction(value) then value.call(object) else value

# Helper function to run parseBeforeLocalSave() in order to
# parse a remote JSON response before caching locally
parseRemoteResponse = (object, response) ->
  if not (object and object.parseBeforeLocalSave) then return response
  if _.isFunction(object.parseBeforeLocalSave) then object.parseBeforeLocalSave(response)

onlineSync = Backbone.sync

dualsync = (method, model, options) ->
  options.storeName = result(model.collection, 'url') || result(model, 'url')
  
  # execute only online sync
  return onlineSync(method, model, options) if result(model, 'remote') or result(model.collection, 'remote')
  
  # execute only local sync
  local = result(model, 'local') or result(model.collection, 'local')
  options.dirty = options.remote is false and not local
  return localsync(method, model, options) if options.remote is false or local
  
  # execute dual sync
  options.ignoreCallbacks = true
  
  success = options.success
  error = options.error
  
  switch method
    when 'read'
      if localsync('hasDirtyOrDestroyed', model, options)
        success localsync(method, model, options)
      else
        remoteOptions = _(options).clone()
        remoteOptions.success = (resp, status, xhr) ->
          resp = parseRemoteResponse(model, resp)
          
          localsync('clear', model, options)
          
          if _.isArray resp
            for i in resp
              localsync('create', i, options)
          else
            localsync('create', resp, options)
          
          success(resp, status, xhr) # ideally this would only be called if we knew that it was different from localStorage, instead of reset()-ing
        
        # remote sync failed, do nothing for now
        # remoteOptions.error = (resp) ->
          
        # after localsync loads, check to see if we should still remotesync
        options.ignoreCallbacks = false
        options.success = (resp) ->
          # first fire the success callback which will populate the model
          success(resp)
          
          # now that the collection is populated from localStorage, check if we should remote
          if _.isUndefined(model.shouldRemoteSync) or (_.isFunction(model.shouldRemoteSync) and model.shouldRemoteSync())
            onlineSync(method, model, remoteOptions)  
          
        localsync(method, model, options)

    when 'create'
      options.success = (resp, status, xhr) ->
        localsync(method, resp, options)
        success(resp, status, xhr)
      options.error = (resp) ->
        options.dirty = true
        success localsync(method, model, options)
      
      onlineSync(method, model, options)

    when 'update'
      if _.isString(model.id) and model.id.length == 36
        originalModel = model.clone()
        
        options.success = (resp, status, xhr) ->
          localsync('delete', originalModel, options)
          localsync('create', resp, options)
          success(resp, status, xhr)
        options.error = (resp) ->
          options.dirty = true
          success localsync(method, originalModel, options)
        
        model.set id: null
        onlineSync('create', model, options)
      else
        options.success = (resp, status, xhr) ->
          success localsync(method, model, options)
        options.error = (resp) ->
          options.dirty = true
          success localsync(method, model, options)
        
        onlineSync(method, model, options)

    when 'delete'
      if _.isString(model.id) and model.id.length == 36
        localsync(method, model, options)
      else
        options.success = (resp, status, xhr) ->
          localsync(method, model, options)
          success(resp, status, xhr)
        options.error = (resp) ->
          options.dirty = true
          success localsync(method, model, options)
        
        onlineSync(method, model, options)
    
Backbone.sync = dualsync
