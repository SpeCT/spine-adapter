db       = require "db"
duality  = require "duality/core"
session  = require "session"


feeds = {} # Cache `_changes` feeds by their url


Spine.Model.CouchChanges = (opts = {})->
  opts.url = opts.url or duality.getDBURL()
  opts.handler = Spine.Model.CouchChanges.Changes unless opts.handler
  return feeds[opts.url] if feeds[opts.url]
  feed = feeds[opts.url] =
    changes: new opts.handler opts
    extended: ->
      # need to keep _rev around to support changes feed processing
      @attributes.push "_rev" unless @attributes[ "_rev" ]
      @changes.subscribe @className, @
  feed.changes.startListening()
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
    else db.use(@url).info (err, info) => # grab update_seq number
      return if err                       #     for the first time
      @query.since = info.update_seq
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
          continue unless doc = change.doc
          continue unless modelname = doc.modelname
          continue unless klass = @subscribers[modelname]
          doc.id = doc._id unless doc.id
          try
            obj = klass.find doc.id
            if change.deleted
              obj.destroy()
            else unless obj._rev is doc._rev
              obj.updateAttributes doc
          catch e
            unless change.deleted
              klass.create doc
            else
              klass.trigger "deleted", doc
              continue
        return

      # call next in Spine.CouchAjax.queue
      complete: (next) -> setTimeout next, 0


# Start listening for _changes only when user is authenticated
#   and stop listening for changes when he logged out
Spine.Model.CouchChanges.PrivateChanges = class PrivateChanges extends Changes
  constructor: ->
    super
    session.on "change", @startListening

  startListening: =>
    @currentHandler.disabled = true if @currentHandler  # - stop
    super if session.userCtx and session.userCtx.name   # - start
