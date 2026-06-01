test -r $DATA_DIR
if [ $? -ne 0 ]; then
  echo "系统用户无法访问数据目录: $DATA_DIR" >&2
  exit 1
fi
