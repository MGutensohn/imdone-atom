request = require 'superagent'
async = require 'async'
authUtil = require './auth-util'
{Emitter} = require 'atom'
Pusher = require 'pusher-js'
_ = require 'lodash'
Task = require 'imdone-core/lib/task'
config = require '../../config'
debug = require('debug/browser')
log = debug 'imdone-atom:client'

# READY:70 The client public_key, secret and pusherKey should be configurable
PROJECT_ID_NOT_VALID_ERR = new Error "Project ID not valid"
baseUrl = config.baseUrl # READY:60 This should be set to localhost if process.env.IMDONE_ENV = /dev/i
baseAPIUrl = "#{baseUrl}/api/1.0"
accountUrl = "#{baseAPIUrl}/account"
signUpUrl = "#{baseUrl}/signup"
pusherAuthUrl = "#{baseUrl}/pusher/auth"

credKey = 'imdone-atom.credentials'
Pusher.log = debug 'imdone-atom:pusher'

module.exports =
class ImdoneioClient extends Emitter
  @PROJECT_ID_NOT_VALID_ERR: PROJECT_ID_NOT_VALID_ERR
  @baseUrl: baseUrl
  @baseAPIUrl: baseAPIUrl
  @signUpUrl: signUpUrl
  authenticated: false

  constructor: () ->
    super
    @loadCredentials (err) =>
      return if err
      @_auth () ->

  setHeaders: (req) ->
    log 'setHeaders:begin'
    withHeaders = req.set('Date', (new Date()).getTime())
      .set('Accept', 'application/json')
      .set('Authorization', authUtil.getAuth(req, "imdone", @email, @password, config.imdoneKeyB, config.imdoneKeyA));
    log 'setHeaders:end'
    withHeaders

  doGet: (path) ->
    log 'doGet:begin'
    withHeaders = @setHeaders request.get("#{baseAPIUrl}#{path || ''}")
    log 'doGet:end'
    withHeaders

  doPost: (path) ->
    @setHeaders request.post("#{baseAPIUrl}#{path}")

  _auth: (cb) ->
    @doGet().end (err, res) =>
      return @onAuthFailure err, res, cb if err || !res.ok
      @onAuthSuccess cb

  onAuthSuccess: (cb) ->
    @getAccount (err, user) =>
      return cb(err) if err
      @saveCredentials (err) =>
        @authenticated = true
        @user = user
        @emit 'authenticated'
        cb(null, user)
        log 'onAuthSuccess'
        @setupPusher()

  onAuthFailure: (err, res, cb) ->
    @authenticated = false
    delete @password
    delete @email
    cb(err, res)

  authenticate: (@email, password, cb) ->
    log 'authenticate:start'
    @password = authUtil.sha password
    @_auth cb

  isAuthenticated: () -> @authenticated

  setupPusher: () ->
    @pusher = new Pusher config.pusherKey,
      encrypted: true
      authEndpoint: pusherAuthUrl
    # READY:30 imdoneio pusher channel needs to be configurable
    @pusherChannel = @pusher.subscribe "#{config.pusherChannelPrefix}-#{@user.id}"
    @pusherChannel.bind 'product.linked', (data) => @emit 'product.linked', data.product
    @pusherChannel.bind 'product.unlinked', (data) => @emit 'product.linked', data.product
    log 'setupPusher'

  saveCredentials: (cb) ->
    @db().remove {}, {}, (err) =>
      log 'saveCredentials'
      return cb err if (err)
      key = authUtil.toBase64("#{@email}:#{@password}")
      @db().insert key: key, cb

  loadCredentials: (cb) ->
    @db().findOne {}, (err, doc) =>
      return cb err if err || !doc
      parts = authUtil.fromBase64(doc.key).split(':')
      @email = parts[0]
      @password = parts[1]
      cb null


  getProducts: (cb) ->
    # READY:120 Implement getProducts
    @doGet("/products").end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  getAccount: (cb) ->
    # DOING:0 getAccount is slow to start, why? id:329
    log 'getAccount:start'
    @doGet("/account").end (err, res) =>
      log 'getAccount:end'
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  getProject: (projectId, cb) ->
    # READY:100 Implement getProject
    @doGet("/projects/#{projectId}").end (err, res) =>
      return cb(PROJECT_ID_NOT_VALID_ERR) if res.body && res.body.kind == "ObjectId" && res.body.name == "CastError"
      return cb err if err
      cb null, res.body

  getTasks: (projectId, taskIds, cb) ->
    # READY:110 Implement getProject
    return cb null, [] unless taskIds && taskIds.length > 0
    @doGet("/projects/#{projectId}/tasks/#{taskIds.join(',')}").end (err, res) =>
      return cb(PROJECT_ID_NOT_VALID_ERR) if res.body && res.body.kind == "ObjectId" && res.body.name == "CastError"
      return cb err if err
      cb null, res.body


  createProject: (repo, cb) ->
    # READY:50 Implement createProject
    @doPost("/projects").send(
      name: repo.getDisplayName()
      localConfig: repo.config.toJSON()
    ).end (err, res) =>
      return cb(err, res) if err || !res.ok
      project = res.body
      _.set repo, 'config.sync.id', project.id
      _.set repo, 'config.sync.name', project.name
      repo.saveConfig()
      cb(null, project)


  getOrCreateProject: (repo, cb) ->
    # READY:40 Implement getOrCreateProject
    projectId = _.get repo, 'config.sync.id'
    return @createProject repo, cb unless projectId
    @getProject projectId, (err, project) =>
      debugger
      _.set repo, 'config.sync.name', project.name
      repo.saveConfig()
      return @createProject repo, cb if err == PROJECT_ID_NOT_VALID_ERR
      return cb err if err
      cb null, project

  createTasks: (repo, project, tasks, product, cb) ->
    # READY:50 Implement createTasks
    # READY:0 modifyTask should update text with metadata that doesn't exists
    updateRepo = (task, cb) => repo.modifyTask new Task(task.localTask, true), cb
    @doPost("/projects/#{project.id}/tasks").send(tasks).end (err, res) =>
      return cb(err, res) if err || !res.ok
      tasks = res.body
      @tasksDb(repo).insert tasks, (err, docs) =>
        async.eachSeries docs, updateRepo, (err) =>
          repo.saveModifiedFiles cb

  updateTasks: (repo, project, product, cb) ->
    # DOING: Should we really do this for all local tasks or do we ask api for task id's and dates only?
    @tasksDb(repo).find {}, (err, localTasks) =>
      localIds = localTasks.map (task) -> task.id
      @getTasks project.id, localIds, (err, cloudTasks) =>
        console.log 'cloudTasks', cloudTasks
        console.log 'localTasks', localTasks
        cloudTasks.forEach (cloudTask) =>
          localTask = _.find(localTasks, {id: cloudTask.id})
          # DOING:0 Compare remote tasks with local tasks for update.  If local task is older pull from imdone.io id:325
        cb()

  syncTasks: (repo, tasks, product, cb) ->
    cb = if cb then cb else () ->
    # DOING:30 Emit progress through the repo so the right board is updated id:327
    @getOrCreateProject repo, (err, project) =>
      return cb(err) if err
      tasksToCreate = tasks.filter (task) -> !_.get(task, "meta.id")
      @updateTasks repo, project, product, (err) =>
        return @createTasks repo, project, tasksToCreate, product, cb if tasksToCreate
        cb err

  # collection can be an array of strings or string
  db: (collection) ->
    path = require 'path'
    collection = path.join.apply @, arguments if arguments.length > 1
    collection = "config" unless collection
    @datastore = {} unless @datastore
    return @datastore[collection] unless !@datastore[collection]
    DataStore = require('nedb')
    @datastore[collection] = new DataStore
      filename: path.join atom.getConfigDirPath(), 'storage', 'imdone-atom', collection
      autoload: true
    @datastore[collection]

  tasksDb: (repo) ->
    #READY:20 return the project specific task DB
    @db 'tasks',repo.getPath().replace(/\//g, '_')

  @instance: new ImdoneioClient