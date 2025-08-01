#!/bin/bash

# --- ЗАГРУЗКА КОНФИГУРАЦИИ ---
CONFIG_FILE="$(dirname "$(readlink -f "$0")")/watcher_cfg.sh"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file '${CONFIG_FILE}' not found. Exiting."
    exit 1
fi

# Перенаправляем весь вывод скрипта в лог-файл с отметкой времени
exec >> "$LOG_FILE" 2>&1

echo "--- $(date) --- Starting watcher ---"

# Проверяем, существует ли файл со списком веток
if [ ! -f "$BRANCHES_FILE" ]; then
    echo "Error: Branches file '${BRANCHES_FILE}' not found. Exiting."
    echo "--- $(date) --- Watcher finished with errors ---"
    exit 1
fi

# Читаем ветки из файла и обрабатываем каждую
while IFS= read -r MODEL_BRANCH || [ -n "$MODEL_BRANCH" ]; do
    [[ -z "$MODEL_BRANCH" || "${MODEL_BRANCH#}" =~ ^# ]] && continue

    echo "Processing branch: ${MODEL_BRANCH}"

    # Путь к директории конкретной модели
    TARGET_MODEL_PATH="${BASE_REPOS_DIR}/${MODEL_BRANCH}"

    # Проверяем, существует ли уже директория с моделью
    if [ -d "$TARGET_MODEL_PATH" ]; then
        echo "Repository for branch '${MODEL_BRANCH}' already exists. Attempting to update."
        cd "$TARGET_MODEL_PATH" || { echo "Error: Failed to change directory to ${TARGET_MODEL_PATH}"; continue; }

        # --- БЛОК GIT STASH ---
        if [[ $(git status --porcelain) ]]; then
            echo "Local changes detected in '${MODEL_BRANCH}'. Stashing them to prevent conflicts."
            
            # Создаем уникальное сообщение, чтобы потом найти stash
            STASH_MESSAGE_ID="Auto-stash for branch ${MODEL_BRANCH} before pull on commit $(git rev-parse --short HEAD) [$(date +%Y%m%d%H%M%S)]"
            git stash push -m "$STASH_MESSAGE_ID"

            if [ $? -ne 0 ]; then
                echo "Error: Failed to stash local changes. Exiting to prevent data loss."
                echo "--- $(date) --- Watcher finished with errors ---"
                exit 1
            fi
            
            # Ищем stash по уникальному сообщению и сохраняем его индекс
            STASH_REF=$(git stash list | grep "$STASH_MESSAGE_ID" | head -n 1 | awk '{print $1}')
            
            if [ -z "$STASH_REF" ]; then
                echo "Error: Could not find the created stash. Exiting."
                echo "--- $(date) --- Watcher finished with errors ---"
                exit 1
            fi

            echo "Local changes successfully stashed. Reference: ${STASH_REF}"
        else
            echo "No local changes detected."
        fi

        # Убедимся, что мы на нужной ветке, прежде чем тянуть изменения
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        if [ "$CURRENT_BRANCH" != "$MODEL_BRANCH" ]; then
            echo "Warning: Not on branch '${MODEL_BRANCH}'. Switching to it."
            git checkout "${MODEL_BRANCH}" || { echo "Error: Failed to checkout branch ${MODEL_BRANCH}"; continue; }
            git pull origin "${MODEL_BRANCH}" # Подтянуть изменения после смены ветки
        fi

        # Проверяем, есть ли изменения на удаленном репозитории
        git remote update --prune # --prune удаляет устаревшие удаленные ветки

        # Сравниваем локальный коммит с удаленным
        LOCAL_COMMIT=$(git rev-parse "${MODEL_BRANCH}")
        REMOTE_COMMIT=$(git rev-parse "origin/${MODEL_BRANCH}")

        if [ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]; then
            echo "Changes detected for branch '${MODEL_BRANCH}'. Pulling updates."
            git pull origin "${MODEL_BRANCH}" || { echo "Error: Failed to pull updates for branch ${MODEL_BRANCH}"; continue; }
            echo "Updates pulled successfully."

            # Запускаем скрипт обучения в новой tmux-сессии
            TMUX_SESSION_NAME="model_training_${MODEL_BRANCH}_$(date +%Y%m%d%H%M%S)"
            echo "Launching training script for '${MODEL_BRANCH}' in tmux session: ${TMUX_SESSION_NAME}"
            # Проверяем, запущен ли tmux. Если нет, запускаем
            if ! tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
                tmux new-session -d -s "$TMUX_SESSION_NAME" "python3 \"$TRAIN_SCRIPT\" && echo 'Training finished for ${MODEL_BRANCH} at $(date)' && exit"
                echo "Training script started. To attach: tmux attach -t ${TMUX_SESSION_NAME}"
            else
                echo "Tmux session '${TMUX_SESSION_NAME}' already exists. Skipping new training session."
            fi
        else
            echo "No changes detected for branch '${MODEL_BRANCH}'. No update needed."
        fi

        # --- БЛОК GIT STASH (ВОССТАНОВЛЕНИЕ) ---
        if [ ! -z "$STASH_REF" ]; then
            echo "Applying stashed changes from ${STASH_REF}..."
            git stash apply "${STASH_REF}" || { echo "Warning: Failed to apply stashed changes from '${STASH_REF}'. Conflicts may exist. Stash will not be dropped."; }
            
            # Если apply был успешным, удаляем stash
            if [ $? -eq 0 ]; then
                echo "Applying successful. Dropping stash ${STASH_REF}."
                git stash drop "${STASH_REF}"
            fi
        fi

    else
        echo "Repository for branch '${MODEL_BRANCH}' does not exist. Cloning it."
        # Возвращаемся в BASE_REPOS_DIR для клонирования
        cd "$BASE_REPOS_DIR" || { echo "Error: Failed to change directory back to ${BASE_REPOS_DIR}"; continue; }

        git clone --depth 1 --branch "${MODEL_BRANCH}" "$GIT_REPO_SSH" "$MODEL_BRANCH" || { echo "Error: Failed to clone repository for branch ${MODEL_BRANCH}"; continue; }
        cd "$TARGET_MODEL_PATH" || { echo "Error: Failed to change directory to newly cloned ${TARGET_MODEL_PATH}"; continue; }

        # После первого клонирования запускаем скрипт
        TMUX_SESSION_NAME="model_training_${MODEL_BRANCH}_$(date +%Y%m%d%H%M%S)"
        echo "Launching training script for '${MODEL_BRANCH}' after initial clone in tmux session: ${TMUX_SESSION_NAME}"
        if ! tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
            tmux new-session -d -s "$TMUX_SESSION_NAME" "python3 \"$TRAIN_SCRIPT\" && echo 'Training finished for ${MODEL_BRANCH} at $(date)' && exit"
            echo "Training script started. To attach: tmux attach -t ${TMUX_SESSION_NAME}"
        else
            echo "Tmux session '${TMUX_SESSION_NAME}' already exists. Skipping new training session."
        fi
    fi
    echo "Finished processing branch: ${MODEL_BRANCH}"
    echo "" # Красивск
done < "$BRANCHES_FILE" # Читаем строки из файла BRANCHES_FILE

echo "--- $(date) --- Watcher finished ---"