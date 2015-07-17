Promise = require 'lie'
utils = require './utils'
GIT_INDEX_FILE = ".git/index-git-n-sync"
path = require 'path'

SYNCER_REF = "__git-n-sync__/head"

remoteToComponents = (remote)->
  [arg1, arg2] = remote.split(":")
  username = arg1.split("@")[0]
  host = arg1.split("@")[1]
  dir = arg2.split(".git")[0]
  return {username, host, dir}

class Syncer
  constructor: ({@srcDir, @remote})->
    # TODO
    # turn srcDir into an absolute path
    # add tests to make sure the user's index is kept clean

  #TODO figure out a less clunky way to do this
  # at some point creating the server repo should create docker
  # container + http proxy in front of it
  configureServer: ->
    {username, host, dir} = remoteToComponents(@remote)
    destination = "#{dir}/.git/hooks/post-receive"
    Promise.all [
      #allow pushing to the active branch
      utils.remoteCmd username, host, dir, "git config receive.denyCurrentBranch ignore",
      utils.writeRemoteFile(username, host, destination, "#{__dirname}/postReceive.js")
    ]

  #ref and branch pointed to by HEAD, ex: {ref: "refs/heads/master" sha: "4ebd20c3b676a7680e07ae382e8d280c6a0e67f6"}
  getHead: ->
    utils.readFile(path.join(@srcDir, ".git", "HEAD")).then (contents)=>
      # example contents: ref: /refs/heads/master, ref would be /refs/heads/master
      ref = /ref: (.*)\n?/.exec(contents)[1]
      utils.readFile(path.join(@srcDir, ".git", ref)).then (file)->
        sha = file.split("\n")[0]
        Promise.resolve {ref, sha}

  # the syncer ref stores the last pushed virtual commit
  # the commit message contains the branch the user was on when the virtual commit was pushed
  getSyncerHead: ->
    utils.cmd(@srcDir, "git show-ref --hash #{SYNCER_REF}").then ({stdout, stderr})->
      return Promise.resolve (stdout.split("\n")[0])
    , ({stdout, stderr})-> #if ref doesn't exist just return a promise that resolves to null
      console.log stdout if stdout
      console.error stderr if stderr
      Promise.resolve null


  # create a fake commit w/ last known user commit and working branch encoded in message
  commitWorkingDir: (parentCommit, message)->
    #GIT_INDEX_FILE env variable allows you to stage files w/o in a separate file,
    #this prevents corruption of the user's staging area
    utils.cmd(@srcDir, "git add -A .", {env: {GIT_INDEX_FILE}}).then =>
      utils.cmd(@srcDir, "git write-tree", {env: {GIT_INDEX_FILE}}).then ({stdout, stderr})=>
        treeHash = stdout.split("\n")[0]
        command = "git commit-tree #{treeHash} -p #{parentCommit} -m \"#{message}\"\n"
        utils.cmd(@srcDir, command).then ({stdout, stderr})->
          commitHash = stdout.split("\n")[0]
          Promise.resolve commitHash

  sync: ->
    @getHead(@srcDir).then ({ref, sha})=>
      @getSyncerHead(@srcDir).then (syncerHead)=>
        message = "git-n-sync commit, you probably shouldn't be seeing this\n\n#{ref} #{sha}"
        # if this is the first time syncing, syncerHead is null and the
        # parent is set to the head fo the current branch
        # for all subsequent syncs the parent is the syncer head
        @commitWorkingDir(syncerHead or sha, message, @srcDir).then (commitHash)=>
          utils.cmd(@srcDir, "git update-ref refs/#{SYNCER_REF} #{commitHash}").then =>
            command = "git push #{@remote} refs/#{SYNCER_REF}:refs/#{SYNCER_REF}"
            console.log "running command #{command}"
            utils.cmd(@srcDir, command).then ({stdout, stderr})->
              console.log stdout if stdout
              console.error stderr if stderr
              #TODO text processing happens here, return nice object
              #as promise

sync = (srcDir, remote)->
  syncer = new Syncer({srcDir, remote})
  syncer.configureServer().then ->
    syncer.sync()


module.exports = sync
