AppConfig         = require 'shared/services/app_config.coffee'
Session           = require 'shared/services/session.coffee'
Records           = require 'shared/services/records.coffee'
AbilityService    = require 'shared/services/ability_service.coffee'
LmoUrlService     = require 'shared/services/lmo_url_service.coffee'
ModalService      = require 'shared/services/modal_service.coffee'
PaginationService = require 'shared/services/pagination_service.coffee'

{ subscribeToLiveUpdate } = require 'angular/helpers/user.coffee'

angular.module('loomioApp').controller 'GroupPageController', ($rootScope, $location, $routeParams, PollService) ->
  $rootScope.$broadcast 'currentComponent', {page: 'groupPage', key: $routeParams.key, skipScroll: true }

  @launchers = []
  @addLauncher = (action, condition = (-> true), opts = {}) =>
    @launchers.push
      priority:       opts.priority || 9999
      action:         action
      condition:      condition
      allowContinue:  opts.allowContinue

  @addLauncher =>
    ModalService.open 'InstallSlackModal',
      group: => @group
      requirePaidPlan: -> true
  , ->
    $location.search().install_slack

  @performLaunch = ->
    @launchers.sort((a, b) -> a.priority - b.priority).map (launcher) =>
      return if (typeof launcher.action != 'function') || @launched
      if launcher.condition()
        launcher.action()
        @launched = true unless launcher.allowContinue

  # allow for chargify reference, which comes back #{groupKey}|#{timestamp}
  # we include the timestamp so chargify sees unique values
  $routeParams.key = $routeParams.key.split('-')[0]
  Records.groups.findOrFetchById($routeParams.key).then (group) =>
    @init(group)
  , (error) ->
    $rootScope.$broadcast('pageError', error)

  @init = (group) =>
    @group = group
    subscribeToLiveUpdate(group_key: @group.key)

    Records.drafts.fetchFor(@group) if AbilityService.canCreateContentFor(@group)

    maxDiscussions = if AbilityService.canViewPrivateContent(@group)
      @group.discussionsCount
    else
      @group.publicDiscussionsCount
    @pageWindow = PaginationService.windowFor
      current:  parseInt($location.search().from or 0)
      min:      0
      max:      maxDiscussions
      pageType: 'groupThreads'

    $rootScope.$broadcast 'currentComponent',
      title: @group.fullName
      page: 'groupPage'
      group: @group
      key: @group.key
      links:
        canonical:   LmoUrlService.group(@group, {}, absolute: true)
        rss:         LmoUrlService.group(@group, {}, absolute: true, ext: 'xml') if !@group.privacyIsSecret()
        prev:        LmoUrlService.group(@group, from: @pageWindow.prev)         if @pageWindow.prev?
        next:        LmoUrlService.group(@group, from: @pageWindow.next)         if @pageWindow.next?

    @performLaunch()

  return
