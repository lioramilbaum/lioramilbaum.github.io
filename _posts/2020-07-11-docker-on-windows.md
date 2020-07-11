---
layout: post
title:  "Docker on Windows"
tags:
  - docker
  - Windows
  - devops
  - lioramilbaum
---

# Docker on Windows

While I was working on <a href="https://github.com/devopsloft/devopsloft/pull/430">Pull Request</a>, I had to make sure it was also working on Windows.

What is the connection between me and Windows? In short, nothing.</br>
And not for short, nothing at all.

Luckily my Loft co-leader has strong conntection with Windows. Without further due, he was chosen for the task.
Wow, what a challenge it was.

All this long story is a short introduction to the challenge we encountered.

## The challenge
<ul>
    <li>OS - Windows</li>
    <li>Container Image baked with ECS CLI</li>
    <li>AWS configuration settings stored in ~/.aws</li>
    <li>~/.aws folder should be shared with the running container</li>
    <li>Using the -v argument apperantly was not enough</li>
</ul>

## The solution
<ul>
    <li>Using '~' for mounting a host directly on containers - not a good idea. Use $HOME instead</li>
    <li>Mounting Windows folders on containers requires <a href="https://token2shell.com/howto/docker/sharing-windows-folders-with-containers/#:~:text=In%20order%20to%20share%20Windows,v%22%20(volume)%20flag.">configuring the "Shared Drives" option in Docker settings</a></li>

    





