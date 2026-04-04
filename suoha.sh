#!/bin/bash
# suoha x-tunnel

linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")
n=0

for i in "${linux_os[@]}"
do
    if [ "$i" == "$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}')" ]
    then
        break
    else
        n=$[$n+1]
    fi
done

if [ "$n" == "5" ]
then
    echo "当前系统 $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2) 没有适配"
    echo "默认使用APT包管理器"
    n=0
fi

if [ -z "$(type -P screen)" ]
then
    ${linux_update[$n]}
    ${linux_install[$n]} screen
fi

if [ -z "$(type -P curl)" ]
then
    ${linux_update[$n]}
    ${linux_install[$n]} curl
fi

function quicktunnel(){
    case "$(uname -m)" in
        x86_64 | x64 | amd64 )
        if [ ! -f "x-tunnel-linux" ]
        then
            curl -L https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-amd64 -o x-tunnel-linux
        fi
        if [ ! -f "cloudflared-linux" ]
        then
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux
        fi
        ;;
        i386 | i686 )
        if [ ! -f "x-tunnel-linux" ]
        then
            curl -L https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-386 -o x-tunnel-linux
        fi
        if [ ! -f "cloudflared-linux" ]
        then
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux
        fi
        ;;
        armv8 | arm64 | aarch64 )
        if [ ! -f "x-tunnel-linux" ]
        then
            curl -L https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-arm64 -o x-tunnel-linux	
        fi
        if [ ! -f "cloudflared-linux" ]
        then
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
        fi
        ;;
        * )
        echo "当前架构 $(uname -m) 没有适配"
        exit
        ;;
    esac

    chmod +x cloudflared-linux x-tunnel-linux
    sleep 1
    wsport=$(get_free_port)
    
    if [ -z "$token" ]
    then
        screen -dmUS x-tunnel ./x-tunnel-linux -l ws://127.0.0.1:$wsport
    else
        screen -dmUS x-tunnel ./x-tunnel-linux -l ws://127.0.0.1:$wsport -token "$token"
    fi
    
    metricsport=$(get_free_port)
    ./cloudflared-linux update
    screen -dmUS argo ./cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel --url 127.0.0.1:$wsport --metrics 0.0.0.0:$metricsport
    
    while true; do
        echo "正在尝试获取内容..."
        RESP=$(curl -s "http://127.0.0.1:$metricsport/metrics")

        # 若curl成功且包含userHostname则处理
        if echo "$RESP" | grep -q 'userHostname='; then
            echo "获取成功，正在解析..."

            # 从返回内容中提取域名
            DOMAIN=$(echo "$RESP" | grep 'userHostname="' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/')

            echo "提取到的域名: $DOMAIN"
            break
        else
            echo "未获取到userHostname, 1秒后重试..."
            sleep 1
        fi
    done
    
    clear
    if [ -z "$token" ]
    then
        echo "未设置token, 链接: $DOMAIN:443"
    else
        echo "已设置token, 链接: $DOMAIN:443 身份令牌: $token"
    fi
    echo "可以访问 http://$(curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2):$metricsport/metrics 查找 userHostname"
}

get_free_port() {
    while true; do
        PORT=$((RANDOM + 1024))  # 避免系统保留端口
        if ! lsof -i TCP:$PORT >/dev/null 2>&1; then
            echo $PORT
            return
        fi
    done
}

clear
echo "梭哈模式不需要自己提供域名, 使用CF ARGO QUICK TUNNEL创建快速链接"
echo "梭哈模式在重启或者脚本再次运行后失效, 如果需要使用需要再次运行创建"
echo -e "\n梭哈是一种智慧!!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈...\n"
echo "1.梭哈模式"
echo "2.停止服务"
echo "3.清空缓存"
echo -e "0.退出脚本\n"

read -p "请选择模式(默认1):" mode
if [ -z "$mode" ]
then
    mode=1
fi

if [ "$mode" == "1" ]
then
    read -p "请选择cloudflared连接模式IPV4或者IPV6(输入4或6,默认4):" ips	
    if [ -z "$ips" ]
    then
        ips=4
    fi
    if [ "$ips" != "4" ] && [ "$ips" != "6" ]
    then
        echo "请输入正确的cloudflared连接模式"
        exit
    fi
    
    read -p "请设置x-tunnel的token(可留空):" token
    screen -wipe
    screen -S x-tunnel -X quit
    
    while true
    do
        if [ $(screen -S x-tunnel -X quit | grep No | grep -v grep | wc -l) -eq 1 ]
        then
            break
        else
            echo "等待x-tunnel退出..."
            sleep 1
        fi
    done
    
    while true
    do
        if [ $(screen -S argo -X quit | grep No | grep -v grep | wc -l) -eq 1 ]
        then
            break
        else
            echo "等待argo退出..."
            sleep 1
        fi
    done
    
    clear
    sleep 1
    quicktunnel

elif [ "$mode" == "2" ]
then
    screen -wipe
    screen -S x-tunnel -X quit
    
    while true
    do
        if [ $(screen -S x-tunnel -X quit | grep No | grep -v grep | wc -l) -eq 1 ]
        then
            break
        else
            echo "等待x-tunnel退出..."
            sleep 1
        fi
    done
    
    while true
    do
        if [ $(screen -S argo -X quit | grep No | grep -v grep | wc -l) -eq 1 ]
        then
            break
        else
            echo "等待argo退出..."
            sleep 1
        fi
    done
    clear
    
elif [ "$mode" == "3" ]
then
    screen -wipe
    screen -S x-tunnel -X quit
    
    while true
    do
        if [ $(screen -S x-tunnel -X quit | grep No | grep -v grep | wc -l) -eq 1 ]
        then
            break
        else
            echo "等待x-tunnel退出..."
            sleep 1
        fi
    done
    
    while true
    do
        if [ $(screen -S argo -X quit | grep No | grep -v grep | wc -l) -eq 1 ]
        then
            break
        else
            echo "等待argo退出..."
            sleep 1
        fi
    done
    clear
    rm -rf cloudflared-linux x-tunnel-linux
else
    echo "退出成功"
    exit
fi
