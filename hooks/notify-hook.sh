#!/bin/bash

# 读取 stdin 的 JSON 输入（Cursor 会发送这个）
input=$(cat)

# 记录到日志文件（用于调试）
echo "[$(date)] Hook triggered" >> /tmp/cursor-hook.log

# 提取关键信息
hook_event_name=$(echo "$input" | grep -o '"hook_event_name":"[^"]*"' | cut -d'"' -f4)
transcript_path=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | cut -d'"' -f4)
conversation_id=$(echo "$input" | grep -o '"conversation_id":"[^"]*"' | cut -d'"' -f4 | cut -c1-8)
generation_id=$(echo "$input" | grep -o '"generation_id":"[^"]*"' | cut -d'"' -f4 | cut -c1-8)
workspace_root=$(echo "$input" | grep -o '"workspace_roots":\["[^"]*"' | cut -d'"' -f4)

# 提取项目名称（从路径中获取最后一个目录名）
project_name=$(basename "$workspace_root")

# 任务ID（用于区分不同任务）
task_id="$conversation_id-$generation_id"

echo "[$(date)] Hook: $hook_event_name, Project: $project_name, Task: $task_id" >> /tmp/cursor-hook.log

# 根据钩子类型处理不同的输入
if [ "$hook_event_name" = "afterAgentResponse" ]; then
    # afterAgentResponse 钩子：从 transcript 提取任务名称，使用 text 作为摘要
    
    # 尝试从 transcript 文件提取第一个用户提问作为任务名称
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        task_name=$(head -50 "$transcript_path" | awk '
            BEGIN { in_query=0; query="" }
            /^user:$/ && !found_first { next }
            /^<user_query>$/ && !found_first { in_query=1; query=""; next }
            /^<\/user_query>$/ && in_query { 
                found_first=1
                print query
                exit
            }
            in_query && NF>0 { query = query (length(query) > 0 ? " " : "") $0 }
        ')
        
        # 清理任务名称，截取前60个字符
        task_name=$(echo "$task_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-60)
    fi
    
    # 如果没有提取到任务名称，使用默认
    if [ -z "$task_name" ]; then
        task_name="AI 任务"
    fi
    
    # 提取 text 字段（AI 的回复内容）作为摘要
    response_text=$(echo "$input" | grep -o '"text":"[^"]*"' | cut -d'"' -f4 | sed 's/\\n/ /g;s/\\t/ /g')
    
    # 使用 Python 清理 markdown 并截取内容（UTF-8 安全）
    summary=$(echo "$response_text" | python3 -c "
import sys
import re

text = sys.stdin.read()

# 清理 markdown 格式符号
text = re.sub(r'\`\`\`[^\`]*\`\`\`', ' ', text)  # 代码块
text = re.sub(r'\`([^\`]+)\`', r'\1', text)  # 行内代码（保留内容）
text = re.sub(r'\*\*([^*]+)\*\*', r'\1', text)  # 粗体
text = re.sub(r'__([^_]+)__', r'\1', text)  # 粗体
text = re.sub(r'\*([^*]+)\*', r'\1', text)  # 斜体
text = re.sub(r'_([^_]+)_', r'\1', text)  # 斜体
text = re.sub(r'^#+\s*', '', text, flags=re.MULTILINE)  # 行首标题
text = re.sub(r'\s#+\s+', ' ', text)  # 文本中的标题符号（如 ' ### '）
text = re.sub(r'^[-*+]\s+', '', text, flags=re.MULTILINE)  # 列表
text = re.sub(r'^\d+\.\s+', '', text, flags=re.MULTILINE)  # 有序列表
text = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', text)  # 链接（保留文本）
text = re.sub(r'\s+', ' ', text)  # 多个空格合并
text = text.strip()

# 截取前 100 个字符
print(text[:100])
")
    
    # 如果没有提取到内容，使用默认消息
    if [ -z "$summary" ]; then
        summary="AI 已完成回复"
    fi
    
elif [ "$hook_event_name" = "stop" ] || [ -z "$hook_event_name" ]; then
    # stop 钩子或未识别的钩子：从 transcript 文件提取
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        # 提取第一个用户提问作为对话标题/任务名称
        task_name=$(head -50 "$transcript_path" | awk '
            BEGIN { in_query=0; query="" }
            /^user:$/ && !found_first { next }
            /^<user_query>$/ && !found_first { in_query=1; query=""; next }
            /^<\/user_query>$/ && in_query { 
                found_first=1
                print query
                exit
            }
            in_query && NF>0 { query = query (length(query) > 0 ? " " : "") $0 }
        ')
        
        # 清理任务名称，截取前60个字符
        task_name=$(echo "$task_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-60)
        
        # 如果没有提取到任务名称，使用默认
        if [ -z "$task_name" ]; then
            task_name="🏁 AI 任务完成"
        fi
        
        # 读取文件最后300行，找到最后一个 "assistant:" 之后的第一段文本作为总结
        summary=$(tail -300 "$transcript_path" | awk '
            BEGIN { in_assistant=0; collecting=0 }
            /^assistant:$/ { in_assistant=1; collecting=0; delete lines; idx=0; next }
            in_assistant && /^\[Thinking\]/ { collecting=0; next }
            in_assistant && /^\[Tool/ { collecting=0; next }
            in_assistant && !/^\[/ && NF>0 { 
                collecting=1
                lines[idx++]=$0 
            }
            END {
                result=""
                for(i=0; i<idx && length(result)<100; i++) {
                    result = result lines[i] " "
                }
                print result
            }
        ')
        
        # 使用 Python 清理 markdown 并截取内容（UTF-8 安全）
        summary=$(echo "$summary" | python3 -c "
import sys
import re

text = sys.stdin.read()

# 清理 markdown 格式符号
text = re.sub(r'\`\`\`[^\`]*\`\`\`', ' ', text)  # 代码块
text = re.sub(r'\`([^\`]+)\`', r'\1', text)  # 行内代码（保留内容）
text = re.sub(r'\*\*([^*]+)\*\*', r'\1', text)  # 粗体
text = re.sub(r'__([^_]+)__', r'\1', text)  # 粗体
text = re.sub(r'\*([^*]+)\*', r'\1', text)  # 斜体
text = re.sub(r'_([^_]+)_', r'\1', text)  # 斜体
text = re.sub(r'^#+\s*', '', text, flags=re.MULTILINE)  # 行首标题
text = re.sub(r'\s#+\s+', ' ', text)  # 文本中的标题符号（如 ' ### '）
text = re.sub(r'^[-*+]\s+', '', text, flags=re.MULTILINE)  # 列表
text = re.sub(r'^\d+\.\s+', '', text, flags=re.MULTILINE)  # 有序列表
text = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', text)  # 链接（保留文本）
text = re.sub(r'\s+', ' ', text)  # 多个空格合并
text = text.strip()

# 截取前 100 个字符
print(text[:100])
")
        
        # 如果没有提取到总结，使用默认消息
        if [ -z "$summary" ] || [ "$summary" = " " ]; then
            summary="对话已结束"
        fi
    else
        task_name="🏁 AI 任务完成"
        summary="对话已结束"
    fi
else
    # 其他钩子类型
    task_name="🔔 Cursor 钩子通知"
    summary="钩子: $hook_event_name"
fi

echo "[$(date)] Task: $task_name | Summary: $summary" >> /tmp/cursor-hook.log

# 使用 terminal-notifier 发送通知（使用完整路径）
# -title: 任务名称
# -subtitle: 项目名称
# -message: AI 回复摘要（100 字）
# -ignoreDnD: 忽略勿扰模式
# -execute: 点击通知时执行的命令（打开特定项目的 Cursor 窗口）
# 注意：不使用 -sender 参数，让通知显示为来自 terminal-notifier
# 这样即使焦点在 Cursor 上也会弹出横幅通知

# 先播放声音（后台执行，不阻塞），避免等 terminal-notifier 完成后才响
afplay /System/Library/Sounds/Glass.aiff &

if [ -n "$workspace_root" ]; then
    # 如果有项目路径，点击时打开该项目
    /opt/homebrew/bin/terminal-notifier \
        -title "$task_name" \
        -subtitle "项目: $project_name" \
        -message "$summary" \
        -execute "open -a Cursor \"$workspace_root\"" \
        -ignoreDnD \
        2>&1 >> /tmp/cursor-hook.log
else
    # 如果没有项目路径，只激活 Cursor 应用
    /opt/homebrew/bin/terminal-notifier \
        -title "$task_name" \
        -subtitle "项目: $project_name" \
        -message "$summary" \
        -activate "com.todesktop.230313mzl4w4u92" \
        -ignoreDnD \
        2>&1 >> /tmp/cursor-hook.log
fi

echo "[$(date)] terminal-notifier executed" >> /tmp/cursor-hook.log

# 记录详细信息到日志
echo "[$(date)] ✅ [$project_name] AI 任务完成 - $task_id" >> /tmp/cursor-hook.log

echo "[$(date)] Notification and dialog sent" >> /tmp/cursor-hook.log

# 返回 JSON 响应给 Cursor（必须的）
echo "{}"
