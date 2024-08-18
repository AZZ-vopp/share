#!/bin/bash

CONFIG_FILE="cau_hinh.txt"
api_base_url="https://api.cloudflare.com/client/v4/zones"

install_dependencies() {
    local dependencies=("jq" "curl" "bc")
    local to_install=()

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            to_install+=("$dep")
        fi
    done

    if [ ${#to_install[@]} -eq 0 ]; then
        echo "Tất cả các gói phụ thuộc đã được cài đặt"
        return
    fi

    if command -v apt-get > /dev/null; then
        sudo apt-get update
        sudo apt-get install -y "${to_install[@]}"
    elif command -v dnf > /dev/null; then
        sudo dnf install -y "${to_install[@]}"
    elif command -v yum > /dev/null; then
        sudo yum install -y "${to_install[@]}"
    elif command -v pacman > /dev/null; then
        sudo pacman -Sy "${to_install[@]}" --noconfirm
    else
        echo "Trình quản lý gói không được hỗ trợ, vui lòng cài đặt thủ công các gói phụ thuộc: ${to_install[*]}"
        exit 1
    fi
}


read_or_generate_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo "Tệp cấu hình không tồn tại, cần nhập thông tin cấu hình:"
        read -p "Email tài khoản CloudFlare: " email
        read -p "CloudFlare API Key: " api_key
        read -p "Tên miền: " domain
        read -p "Tên miền để tạo phòng thủ: " cache_domain
        read -p "Ngưỡng tải CPU (%): " cpu_threshold
        read -p "Thời gian khôi phục CPU bình thường (giây): " recover_time
        

        zone_id=$(curl -s -X GET "$api_base_url?name=$domain" \
                    -H "X-Auth-Email: $email" \
                    -H "X-Auth-Key: $api_key" \
                    -H "Content-Type: application/json" | jq -r '.result[0].id')

        if [ -z "$zone_id" ];then
            echo "Không thể lấy Zone ID, vui lòng kiểm tra tên miền và thông tin API"
            exit 1
        fi


        cat <<EOF > $CONFIG_FILE
email=$email
api_key=$api_key
domain=$domain
zone_id=$zone_id
cache_domain=$cache_domain
cpu_threshold=$cpu_threshold
recover_time=$recover_time
EOF
    fi
}

check_defense_rule() {
    local rule_name=$1
    local ruleset_id=$(curl -s -X GET "$api_base_url/$zone_id/rulesets?kind=zone&phase=http_request_cache_settings" \
        -H "X-Auth-Email: $email" \
        -H "X-Auth-Key: $api_key" \
        -H "Content-Type: application/json" | jq -r '.result[] | select(.name == "'"$cache_domain"' Ruleset") | .id')

    if [[ -n "$ruleset_id" ]]; then
        rule_exists=$(curl -s -X GET "$api_base_url/$zone_id/rulesets/$ruleset_id" \
            -H "X-Auth-Email: $email" \
            -H "X-Auth-Key: $api_key" \
            -H "Content-Type: application/json" | jq -r '.result.rules[] | select(.description == "'"$rule_name"'")')
        
        if [[ -n "$rule_exists" ]]; then
            return 0 # Quy tắc tồn tại
        else
            return 1 # Quy tắc không tồn tại
        fi
    else
        return 1 # Bộ quy tắc không tồn tại
    fi
}


delete_existing_ruleset() {
    local ruleset_id=$(curl -s -X GET "$api_base_url/$zone_id/rulesets?kind=zone&phase=http_request_cache_settings" \
        -H "X-Auth-Email: $email" \
        -H "X-Auth-Key: $api_key" \
        -H "Content-Type: application/json" | jq -r '.result[] | .id')

    if [[ -n "$ruleset_id" ]]; then
        for id in $ruleset_id; do
            curl -s -X DELETE "$api_base_url/$zone_id/rulesets/$id" \
                -H "X-Auth-Email: $email" \
                -H "X-Auth-Key: $api_key" \
                -H "Content-Type: application/json"
        done
    fi
}

create_or_update_defense_rule() {
    local rule_name="zdwaf"
    if check_defense_rule "$rule_name"; then
        echo "Quy tắc phòng thủ đã tồn tại, không cần tạo quy tắc mới."
        return
    fi

    echo "Tạo hoặc cập nhật quy tắc phòng thủ..."

    ruleset_id=$(curl -s -X GET "$api_base_url/$zone_id/rulesets?kind=zone&phase=http_request_cache_settings" \
        -H "X-Auth-Email: $email" \
        -H "X-Auth-Key: $api_key" \
        -H "Content-Type: application/json" | jq -r '.result[] | select(.name == "'"$cache_domain"' Ruleset") | .id')

    if [[ -n "$ruleset_id" ]]; then
        PAGE_RULE_RESPONSE=$(curl -s -X PUT "$api_base_url/$zone_id/rulesets/$ruleset_id" \
            -H "X-Auth-Email: $email" \
            -H "X-Auth-Key: $api_key" \
            -H "Content-Type: application/json" \
            --data '{
                "rules": [
                    {
                        "expression": "(http.host eq \"'"$cache_domain"'\")",
                        "description": "'"$rule_name"'",
                        "action": "set_cache_settings",
                        "action_parameters": {
                            "cache": true
                        }
                    }
                ]
            }')
    else
        PAGE_RULE_RESPONSE=$(curl -s -X POST "$api_base_url/$zone_id/rulesets" \
            -H "X-Auth-Email: $email" \
            -H "X-Auth-Key: $api_key" \
            -H "Content-Type: application/json" \
            --data '{
                "kind": "zone",
                "name": "'"$cache_domain"' Ruleset",
                "phase": "http_request_cache_settings",
                "rules": [
                    {
                        "expression": "(http.host eq \"'"$cache_domain"'\")",
                        "description": "'"$rule_name"'",
                        "action": "set_cache_settings",
                        "action_parameters": {
                            "cache": true
                        }
                    }
                ]
            }')
    fi

    if [[ "$(echo "$PAGE_RULE_RESPONSE" | jq -r '.success')" != "true" ]]; then
        error_message=$(echo "$PAGE_RULE_RESPONSE" | jq -r '.errors[] | .message')
        echo "Tạo hoặc cập nhật quy tắc phòng thủ thất bại: $error_message"

        # Nếu lỗi là do vượt quá số lượng bộ quy tắc tối đa, hỏi người dùng có muốn xóa bộ quy tắc hiện có không
        if [[ "$error_message" == *"exceeded maximum number of zone rulesets for phase http_request_cache_settings"* ]]; then
            read -p "Đã đạt đến số lượng bộ quy tắc tối đa. Bạn có muốn xóa bộ quy tắc http_request_cache_settings hiện có để tiếp tục không? (y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                echo "Đang xóa bộ quy tắc http_request_cache_settings hiện có..."
                delete_existing_ruleset

                PAGE_RULE_RESPONSE=$(curl -s -X POST "$api_base_url/$zone_id/rulesets" \
                    -H "X-Auth-Email: $email" \
                    -H "X-Auth-Key: $api_key" \
                    -H "Content-Type: application/json" \
                    --data '{
                        "kind": "zone",
                        "name": "'"$cache_domain"' Ruleset",
                        "phase": "http_request_cache_settings",
                        "rules": [
                            {
                                "expression": "(http.host eq \"'"$cache_domain"'\")",
                                "description": "'"$rule_name"'",
                                "action": "set_cache_settings",
                                "action_parameters": {
                                    "cache": true
                                }
                            }
                        ]
                    }')

                if [[ "$(echo "$PAGE_RULE_RESPONSE" | jq -r '.success')" == "true" ]]; then
                    echo "Quy tắc phòng thủ đã được tạo thành công"
                else
                    echo "Tạo quy tắc phòng thủ thất bại lần nữa, vui lòng kiểm tra cấu hình và quyền truy cập tài khoản CloudFlare."
                fi
            else
                echo "Đã hủy thao tác xóa."
            fi
        fi
    else
        echo "Quy tắc phòng thủ đã được tạo hoặc cập nhật thành công"
    fi
}

monitor_cpu_and_manage_rules() {
    rule_active=false
    while true; do
        # Thông báo chào mừng
        echo "============================"
        echo "   Joey Huang BLOG - jhb.ovh"
        echo "   Chào mừng sử dụng script chống DDoS CC tấn công"
        echo "   Nhóm TG: https://t.me/+ft-zI76oovgwNmRh"
        echo "============================"
        echo 

        # Lấy tải CPU
        cpu_load=$(uptime | awk -F 'load average: ' '{print $2}' | cut -d',' -f1 | xargs)
        cpu_load=$(echo "$cpu_load * 100" | bc)

        echo "Tải CPU hiện tại: $cpu_load%"
        
        if (( $(echo "$cpu_load > $cpu_threshold" | bc -l) )); then
            echo "Tải CPU vượt quá ngưỡng, tạo hoặc cập nhật quy tắc phòng thủ..."
            create_or_update_defense_rule
            rule_active=true
        else
            if [ "$rule_active" = true ]; then
                echo "Tải CPU đã bình thường, chờ $recover_time giây rồi tắt quy tắc phòng thủ..."
                sleep "$recover_time"
                echo "Tắt quy tắc phòng thủ..."
                delete_existing_ruleset
                rule_active=false
            else
                echo "Tải CPU chưa vượt ngưỡng, quy tắc phòng thủ không thay đổi."
            fi
        fi

        sleep 1
    done
}


install_dependencies


read_or_generate_config


monitor_cpu_and_manage_rules
