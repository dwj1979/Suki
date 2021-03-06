utils = require './utils'
async = require 'async'

module.exports = Controller = class
  @baseURL = ''

  @supportActions =
    index:
      method: 'get'
      url: '/{{module}}'
    new:
      method: 'get'
      url: '/{{module}}/new'
    create:
      method: 'post'
      url: '/{{module}}'
    show:
      method: 'get'
      url: '/{{module}}/{{id}}'
    edit:
      method: 'get'
      url: '/{{module}}/{{id}}/edit'
    update:
      method: 'put'
      url: '/{{module}}/{{id}}'
    patch:
      method: 'patch'
      url: '/{{module}}/{{id}}'
    destroy:
      method: 'delete'
      url: '/{{module}}/{{id}}'

  @before: (action, condition) ->
    unless @_beforeActions
      @_beforeActions = []

    if condition
      if typeof condition.only is 'string'
        condition.only = [condition.only]
      if typeof condition.except is 'string'
        condition.except = [condition.except]

    @_beforeActions.push
      action: action
      condition: condition

  _fetchInjections: (actionName) ->
    [req, res, self, next] = [@req, @res, @, @next]
    services = req.app.get 'suki.services'
    getInjections = (fn) ->
      injections = utils.di fn
      injections.map (injection) ->
        idName = idName = utils.inflection.toId injection
        modelName = utils.capitalize injection
        model = req.app.get "model#{modelName}"
        if req.params[idName] isnt undefined
          if self["load#{modelName}"]
            (callback) ->
              self.next = callback
              self._fetchInjections "load#{modelName}"
          else
            (callback) ->
              if model then model.find(req.params[idName]).complete callback
              else
                throw new Error [
                  "Can't load the injection '#{injection}'.",
                  "You should either define the `load#{modelName}` action",
                  "or create a model named '#{modelName}'."
                ].join(' ')
        else if req.app.get injection
          (callback) -> callback null, req.app.get injection
        else if services?[injection]
          (callback) -> services[injection] req, res, callback
        else throw new Error "Can't find the injection '#{injection}'"

    injections = getInjections @[actionName]
    async.series injections, (err, result) =>
      @next = next
      if err
        @next err
      else
        @[actionName] result...

  @_mapToRoute: (app) ->
    for own action, body of @prototype
      do (action, body) =>
        return unless typeof body is 'function'
        splitedAction = utils.splitByCapital action
        actionList = Object.keys @supportActions
        return unless actionList.some (actionPrefix) ->
          actionPrefix is splitedAction[0]

        resources = []
        for item, index in splitedAction
          if index is 0
            resources.push @
            resources.action = item
          else
            resources.push item

        resources.url = ''
        for resource, index in resources
          routerName =
            if resource is @ then @routerName
            else utils.inflection.toRouter resource
          idName =
            if resource is @ then @idName
            else utils.inflection.toId resource
          baseAction =
            if index is resources.length - 1 then resources.action
            else 'show'
          definition = @supportActions[baseAction]

          resources.url += definition.url
            .replace('{{module}}', routerName)
            .replace('{{id}}', ":#{idName}")

        middlewares = []

        # Store the controller instance in the `req`
        middlewares.push (req, res, next) =>
          instance = new @
          instance.req = req
          instance.req.controller = @modelName
          instance.req.action = action
          instance.res = res
          req.__suki_controller_instance = instance
          next()

        # redefine `res.render`
        middlewares.push (req, res, next) ->
          instance = req.__suki_controller_instance
          render = res.render
          res.render = (view, locals, callback) ->
            if typeof locals is 'function'
              callback = locals
              locals = undefined

            view = "#{req.controller}/#{req.action}" unless view

            locals = {} unless locals

            for own key, value of instance
              continue if key[0] is '_'
              locals[key] = value

            if callback
              render.call res, view, locals, callback
            else
              render.call res, view, locals
          next()

        # Apply beforeAction
        if @_beforeActions
          @_beforeActions.forEach (beforeAction) ->
            if beforeAction.condition
              if beforeAction.only
                return unless ~beforeAction.only.indexOf action
              else if beforeAction.except
                return unless beforeAction.except.indexOf action

            if typeof beforeAction.action is 'string'
              middlewares.push (req, res, next) ->
                instance = req.__suki_controller_instance
                instance.next = next
                instance._fetchInjections beforeAction.action
            else if typeof beforeAction.action is 'function'
              middlewares.push beforeAction.action

        middlewares.push (req, res, next) ->
          instance = req.__suki_controller_instance
          instance.next = next
          instance._fetchInjections action

        method = @supportActions[resources.action].method
        app[method] @baseURL + resources.url, middlewares
