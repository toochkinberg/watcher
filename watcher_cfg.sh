#!/bin/bash
# --- Конфигурация для deploy_watcher.sh ---

BASE_REPOS_DIR="/home/toochkinberg/test/neural_projects/models"

GIT_REPO_URL="git@github.com:user/reponame.git"

BRANCHES_FILE="$(dirname "$(readlink -f "$0")")/branches_to_monitor.txt"

TRAIN_SCRIPT="test.py"

LOG_FILE="$(dirname "$(readlink -f "$0")")/deploy_watcher.log"