# 第三方组件与授权

本项目是一个图形界面，实际的模型推理由下列开源项目完成。发布或分发本项目时，
请保留它们的版权与许可声明。

| 组件 | 作者/组织 | 许可证 | 地址 |
| --- | --- | --- | --- |
| Demucs | Meta Platforms, Inc. | MIT | https://github.com/facebookresearch/demucs |
| demucs-mlx | ssmall256 | MIT | https://github.com/ssmall256/demucs-mlx |
| MLX | Apple | MIT | https://github.com/ml-explore/mlx |
| 预训练权重 `htdemucs` / `htdemucs_ft` | ssmall256/demucs-mlx（Hugging Face） | MIT | https://huggingface.co/ssmall256/demucs-mlx |

说明：

- 模型权重由 `demucs_mlx` 在首次使用时从 Hugging Face 下载并按 SHA-256 校验，
  本仓库不包含这些权重文件。
- Demucs 的论文与引用信息见上游仓库；如果用于学术用途，请一并引用。
- 上游数据集（如 MUSDB18）可能有独立的使用条款，商用前请自行确认。
