db = # HACK: emulate changes mathod of kanso `db` module
  use: (url, opts) ->
    jqcouch = $.couch.db url
    jqcouch.uri = $.couch.urlPrefix + "/#{url}/"
    changes: (query, callback) ->
      query = $.extend {}, include_docs: true, query
      feed = jqcouch.changes query.since, query
      feed.onChange (data) ->
        feed.stop() unless callback null, data
    info: (callback) ->
      jqcouch.info()
        .done(callback.bind null, null)
        .error(callback)


feeds = {} # Cache `_changes` feeds by their url


Spine.Model.CouchChanges = (opts = {}) ->
  opts.autoconnect or= false
  opts.url = opts.url or Spine.Model.host
  opts.handler = Spine.Model.CouchChanges.Changes unless opts.handler
  return feeds[opts.url] if feeds[opts.url]
  feed = feeds[opts.url] =
    changes: new opts.handler opts
    extended: ->
      # need to keep _rev around to support changes feed processing
      @attributes.push "_rev" unless @attributes[ "_rev" ]
      @changes.subscribe @className, @
  feed.changes.startListening() if opts.autoconnect
  feed


Spine.Model.CouchChanges.reconnect = ->
  for url, feed of feeds
    feed.changes.startListening()


Spine.Model.CouchChanges.Changes = class Changes
  subscribers: {}

  constructor: (options = {}) ->
    @url = options.url
    @query = include_docs: yes

  subscribe: (classname, klass) =>
    @subscribers[classname.toLowerCase()] = klass

  startListening: =>
    connectFeed = => db.use(@url).changes @query, @handler()
    if @query.since then connectFeed()
    else db.use(@url).info (err, resp) => # grab update_seq number
      return if err                       #     for the first time
      @query.since = resp.update_seq
      connectFeed()

  # returns handler which you may disable by setting handler.disabled flag `true`
  handler: ->
    # disable already registered handler
    @currentHandler.disabled = true if @currentHandler
    @currentHandler = (err, resp) => # register new one
      @currentHandler.disabled = true if err
      if @currentHandler.disabled then false
      else if err then false # TODO? @trigger error
      else
        @acceptChanges resp.results
        @query.since = resp.last_seq
        true

  acceptChanges: (changes) ->
    return unless changes
    Spine.CouchAjax.queue =>
      Spine.CouchAjax.disable =>
        for change in changes
          if modelname = change.doc?.modelname
            klass = @subscribers[modelname]
          unless klass
            console.warn "changes: can't find subscriber for #{change.doc.modelname}"
            continue
          doc = change.doc
          doc.id = doc._id unless doc.id
          try
            obj = klass.find doc.id
            if change.deleted
              obj.destroy()
            else
              unless obj._rev is doc._rev
                obj.updateAttributes doc
          catch e
            unless change.deleted
              klass.create doc
            else
              klass.trigger "deleted", doc
              continue
      complete: (next) -> setTimeout next, 0
